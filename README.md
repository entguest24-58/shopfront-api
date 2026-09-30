# shopfront-api

A small e-commerce HTTP API: customer accounts, a product catalog, a shopping cart and checkout.
Node 20 + TypeScript + Express, backed by PostgreSQL.

## Run locally

```bash
npm install
DATABASE_URL=postgresql://app:app@localhost:5432/shopfront JWT_SECRET=change-me PORT=3000 npm run dev
```

The schema (`db/schema.sql`) is applied on startup and seeds a starter catalog of 240 products.

| Variable | Required | Purpose |
|---|---|---|
| `DATABASE_URL` | yes | PostgreSQL connection string |
| `JWT_SECRET` | recommended | secret used to sign access tokens |
| `PORT` | no | listen port (default `3000`) |

## API

All bodies are JSON. Money is in integer cents. Authenticated routes take
`Authorization: Bearer <token>` from `POST /auth/login`.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | – | liveness + database check |
| POST | `/auth/register` | – | create a customer account |
| POST | `/auth/login` | – | exchange email + password for an access token |
| GET | `/products` | – | search the catalog (`q`, `category`, `page`, `page_size`) |
| GET | `/products/:id` | – | product detail |
| POST / PATCH / DELETE | `/products[/:id]` | admin | manage the catalog |
| GET | `/cart` | customer | view cart |
| POST | `/cart/items` | customer | add a product to the cart |
| DELETE | `/cart/items/:productId` | customer | remove a line |
| POST | `/orders` | customer | checkout the cart (optional `coupon_code`) |
| GET | `/orders/:id` | customer | order detail |
