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
