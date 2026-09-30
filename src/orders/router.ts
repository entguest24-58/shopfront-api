import { Response, Router } from 'express';
import { pool, withTransaction } from '../db';
import { AuthedRequest, requireAuth } from '../auth/tokens';

export const ordersRouter = Router();
ordersRouter.use(requireAuth);

const TAX_RATE = 0.08;

interface Coupon {
  percentOff: number;
  minSubtotalCents: number;
}

const COUPONS: Record<string, Coupon> = {
  SAVE10: { percentOff: 10, minSubtotalCents: 5000 },
  WELCOME15: { percentOff: 15, minSubtotalCents: 10000 },
};

class CheckoutError extends Error {
  constructor(public status: number, message: string, public details?: Record<string, unknown>) {
    super(message);
  }
}

interface LockedLine {
  product_id: number;
  name: string;
  price_cents: number;
  stock: number;
  quantity: number;
}

/** Checkout: turns the signed-in customer's cart into an order. */
ordersRouter.post('/', async (req: AuthedRequest, res: Response) => {
  const userId = req.user!.id;
  const rawCoupon = req.body?.coupon_code;
  const couponCode = typeof rawCoupon === 'string' && rawCoupon.trim() ? rawCoupon.trim().toUpperCase() : null;
  const coupon = couponCode ? COUPONS[couponCode] : undefined;
  if (couponCode && !coupon) {
    res.status(422).json({ error: 'unknown coupon code' });
    return;
  }

  try {
    const order = await withTransaction(async (client) => {
      const { rows: lines } = await client.query<LockedLine>(
        `SELECT c.product_id, p.name, p.price_cents, p.stock, c.quantity
           FROM cart_items c JOIN products p ON p.id = c.product_id
          WHERE c.user_id = $1
          ORDER BY c.product_id
          FOR UPDATE OF p`,
        [userId],
      );
      if (lines.length === 0) {
        throw new CheckoutError(400, 'cart is empty');
      }
      const short = lines.filter((l) => l.quantity > l.stock);
      if (short.length > 0) {
        throw new CheckoutError(409, 'not enough stock', {
          items: short.map((l) => ({ product_id: l.product_id, requested: l.quantity, available: l.stock })),
        });
      }

      const subtotal = lines.reduce((sum, l) => sum + l.price_cents * l.quantity, 0);
      if (coupon && subtotal < coupon.minSubtotalCents) {
        throw new CheckoutError(422, 'coupon requires a higher subtotal', { min_subtotal_cents: coupon.minSubtotalCents });
      }
      const discount = coupon ? Math.round((subtotal * coupon.percentOff) / 100) : 0;
      const tax = Math.round((subtotal - discount) * TAX_RATE);
      const total = subtotal - discount + tax;

      const { rows } = await client.query<{ id: number; created_at: Date }>(
        `INSERT INTO orders (user_id, subtotal_cents, discount_cents, tax_cents, total_cents, coupon_code)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, created_at`,
        [userId, subtotal, discount, tax, total, couponCode],
      );
      const orderId = rows[0].id;
      for (const l of lines) {
        await client.query(
          'INSERT INTO order_items (order_id, product_id, name, unit_price_cents, quantity) VALUES ($1, $2, $3, $4, $5)',
          [orderId, l.product_id, l.name, l.price_cents, l.quantity],
        );
        await client.query('UPDATE products SET stock = stock - $2, updated_at = now() WHERE id = $1', [l.product_id, l.quantity]);
      }
      await client.query('DELETE FROM cart_items WHERE user_id = $1', [userId]);

      return {
        id: orderId,
        status: 'placed',
        items: lines.map((l) => ({
          product_id: l.product_id,
          name: l.name,
          unit_price_cents: l.price_cents,
          quantity: l.quantity,
          line_total_cents: l.price_cents * l.quantity,
        })),
        subtotal_cents: subtotal,
        discount_cents: discount,
        tax_cents: tax,
        total_cents: total,
        coupon_code: couponCode,
        created_at: rows[0].created_at,
      };
    });
    res.status(201).json(order);
  } catch (err) {
    if (err instanceof CheckoutError) {
      res.status(err.status).json({ error: err.message, ...(err.details ?? {}) });
      return;
    }
    throw err;
  }
});

ordersRouter.get('/:id', async (req: AuthedRequest, res: Response) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  const { rows } = await pool.query('SELECT * FROM orders WHERE id = $1', [id]);
  if (rows.length === 0) {
    res.status(404).json({ error: 'order not found' });
    return;
  }
  const items = await pool.query(
    'SELECT product_id, name, unit_price_cents, quantity, unit_price_cents * quantity AS line_total_cents FROM order_items WHERE order_id = $1 ORDER BY product_id',
    [id],
  );
  res.json({ ...rows[0], items: items.rows });
});
