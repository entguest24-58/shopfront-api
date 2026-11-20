import { Request, Response, Router } from 'express';
import { pool } from '../db';
import { AuthedRequest, requireAdmin, requireAuth } from '../auth/tokens';

export const productsRouter = Router();

const DEFAULT_PAGE_SIZE = 20;
const MAX_PAGE_SIZE = 100;

interface ProductRow {
  id: number;
  sku: string;
  name: string;
  description: string;
  category: string;
  price_cents: number;
  stock: number;
  active: boolean;
  created_at: Date;
  updated_at: Date;
}

function toProduct(row: ProductRow) {
  return {
    id: row.id,
    sku: row.sku,
    name: row.name,
    description: row.description,
    category: row.category,
    price_cents: row.price_cents,
    stock: row.stock,
    in_stock: row.stock > 0,
  };
}

/** Public catalog search: active products only, optional text + category filter, paginated. */
productsRouter.get('/', async (req: Request, res: Response) => {
  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  const category = typeof req.query.category === 'string' ? req.query.category.trim() : '';
  const page = req.query.page ?? 1;
  const requestedSize = Number(req.query.page_size ?? DEFAULT_PAGE_SIZE);
  const pageSize = Math.min(Math.max(Number.isFinite(requestedSize) ? requestedSize : DEFAULT_PAGE_SIZE, 1), MAX_PAGE_SIZE);

  const where: string[] = ['active = true'];
  const params: unknown[] = [];
  if (q) {
    params.push(`%${q}%`);
    where.push(`(name ILIKE $${params.length} OR description ILIKE $${params.length})`);
  }
  if (category) {
    params.push(category);
    where.push(`category = $${params.length}`);
  }
  const whereSql = where.join(' AND ');

  const countResult = await pool.query<{ total: string }>(`SELECT count(*) AS total FROM products WHERE ${whereSql}`, params);
  const listParams = [...params, pageSize, page];
  const { rows } = await pool.query<ProductRow>(
    `SELECT * FROM products WHERE ${whereSql}
     ORDER BY id
     LIMIT $${listParams.length - 1} OFFSET ($${listParams.length} - 1) * $${listParams.length - 1}`,
    listParams,
  );

  res.json({
    items: rows.map(toProduct),
    page: Number(page),
    page_size: pageSize,
    total: Number(countResult.rows[0].total),
  });
});

productsRouter.get('/:id', async (req: Request, res: Response) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  const { rows } = await pool.query<ProductRow>('SELECT * FROM products WHERE id = $1 AND active = true', [id]);
  if (rows.length === 0) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  res.json(toProduct(rows[0]));
});

// ---- Admin catalog management -------------------------------------------------------------

productsRouter.post('/', requireAuth, requireAdmin, async (req: AuthedRequest, res: Response) => {
  const { sku, name, description = '', category, price_cents, stock = 0 } = req.body ?? {};
  if (typeof sku !== 'string' || !sku.trim() || typeof name !== 'string' || !name.trim() || typeof category !== 'string' || !category.trim()) {
    res.status(400).json({ error: 'sku, name and category are required' });
    return;
  }
  if (!Number.isInteger(price_cents) || price_cents < 0 || !Number.isInteger(stock) || stock < 0) {
    res.status(400).json({ error: 'price_cents and stock must be non-negative integers' });
    return;
  }
  try {
    const { rows } = await pool.query<ProductRow>(
      `INSERT INTO products (sku, name, description, category, price_cents, stock)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
      [sku.trim(), name.trim(), String(description), category.trim(), price_cents, stock],
    );
    res.status(201).json(toProduct(rows[0]));
  } catch (err) {
    if ((err as { code?: string }).code === '23505') {
      res.status(409).json({ error: 'sku already exists' });
      return;
    }
    throw err;
  }
});

productsRouter.patch('/:id', requireAuth, requireAdmin, async (req: AuthedRequest, res: Response) => {
  const id = Number(req.params.id);
  const { name, description, category, price_cents, stock } = req.body ?? {};
  if (price_cents !== undefined && (!Number.isInteger(price_cents) || price_cents < 0)) {
    res.status(400).json({ error: 'price_cents must be a non-negative integer' });
    return;
  }
  if (stock !== undefined && (!Number.isInteger(stock) || stock < 0)) {
    res.status(400).json({ error: 'stock must be a non-negative integer' });
    return;
  }
  const { rows } = await pool.query<ProductRow>(
    `UPDATE products SET
       name = COALESCE($2, name),
       description = COALESCE($3, description),
       category = COALESCE($4, category),
       price_cents = COALESCE($5, price_cents),
       stock = COALESCE($6, stock),
       updated_at = now()
     WHERE id = $1 AND active = true
     RETURNING *`,
    [id, name ?? null, description ?? null, category ?? null, price_cents ?? null, stock ?? null],
  );
  if (rows.length === 0) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  res.json(toProduct(rows[0]));
});

productsRouter.delete('/:id', requireAuth, requireAdmin, async (req: AuthedRequest, res: Response) => {
  const id = Number(req.params.id);
  const { rowCount } = await pool.query('UPDATE products SET active = false, updated_at = now() WHERE id = $1 AND active = true', [id]);
  if (!rowCount) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  res.status(204).end();
});

// ---- Reviews -------------------------------------------------------------------------------

const MAX_COMMENT_LENGTH = 1000;

interface ReviewRow {
  id: number;
  product_id: number;
  user_id: number;
  rating: number;
  comment: string;
  created_at: Date;
  updated_at: Date;
}

function toReview(row: ReviewRow) {
  return {
    id: row.id,
    product_id: row.product_id,
    user_id: row.user_id,
    rating: row.rating,
    comment: row.comment,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

async function activeProductExists(id: number): Promise<boolean> {
  const { rowCount } = await pool.query('SELECT 1 FROM products WHERE id = $1 AND active = true', [id]);
  return Boolean(rowCount);
}

/** A signed-in buyer of the product rates it 1-5 with an optional comment; posting again replaces their review. */
productsRouter.post('/:id/reviews', requireAuth, async (req: AuthedRequest, res: Response) => {
  const productId = Number(req.params.id);
  if (!Number.isInteger(productId) || productId <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  // Only rating and comment are read: the author and dates always come from the server.
  const { rating, comment = '' } = req.body ?? {};
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
    res.status(400).json({ error: 'rating must be a whole number from 1 to 5' });
    return;
  }
  if (typeof comment !== 'string') {
    res.status(400).json({ error: 'comment must be text' });
    return;
  }
  if (comment.length > MAX_COMMENT_LENGTH) {
    res.status(400).json({ error: `comment must be at most ${MAX_COMMENT_LENGTH} characters` });
    return;
  }
  if (!(await activeProductExists(productId))) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  const { rowCount: bought } = await pool.query(
    `SELECT 1 FROM order_items oi JOIN orders o ON o.id = oi.order_id
     WHERE o.user_id = $1 AND oi.product_id = $2 LIMIT 1`,
    [req.user!.id, productId],
  );
  if (!bought) {
    res.status(403).json({ error: 'only buyers of this product can review it' });
    return;
  }
  const { rows } = await pool.query<ReviewRow>(
    `INSERT INTO product_reviews (product_id, user_id, rating, comment)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (product_id, user_id)
     DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, updated_at = now()
     RETURNING *`,
    [productId, req.user!.id, rating, comment],
  );
  res.status(201).json(toReview(rows[0]));
});

/** A buyer deletes their own review of a product. There is no review id: no one can delete another buyer's review. */
productsRouter.delete('/:id/reviews', requireAuth, async (req: AuthedRequest, res: Response) => {
  const productId = Number(req.params.id);
  if (!Number.isInteger(productId) || productId <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  const { rowCount } = await pool.query('DELETE FROM product_reviews WHERE product_id = $1 AND user_id = $2', [
    productId,
    req.user!.id,
  ]);
  if (!rowCount) {
    res.status(404).json({ error: 'review not found' });
    return;
  }
  res.status(204).end();
});

/** Anyone can read a product's reviews, newest first, with the average rating and the count. */
productsRouter.get('/:id/reviews', async (req: Request, res: Response) => {
  const productId = Number(req.params.id);
  if (!Number.isInteger(productId) || productId <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  if (!(await activeProductExists(productId))) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  const { rows } = await pool.query<ReviewRow>(
    'SELECT * FROM product_reviews WHERE product_id = $1 ORDER BY updated_at DESC, id DESC',
    [productId],
  );
  const count = rows.length;
  const average = count ? Math.round((rows.reduce((sum, r) => sum + r.rating, 0) / count) * 10) / 10 : null;
  res.json({ product_id: productId, average, count, reviews: rows.map(toReview) });
});
