
TRUNCATE deliveries, addresses, reviews, payments, order_items, orders,
         cart_items, carts, stock, products, categories, sellers, users
RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- ЧАСТЬ 1. НАПОЛНЕНИЕ
-- ---------------------------------------------------------------------

-- 1. Пользователи
INSERT INTO users (full_name, email, phone)
SELECT 'Пользователь ' || g,
       'user' || g || '@example.com',
       CASE WHEN g % 10 = 0 THEN NULL
            ELSE '+7900' || lpad(g::text, 7, '0') END
FROM generate_series(1, 1200) AS g;

-- 2. Продавцы
INSERT INTO sellers (user_id, store_name, description)
SELECT g,
       'Магазин ' || g,
       CASE WHEN g % 5 = 0 THEN NULL ELSE 'Описание магазина ' || g END
FROM generate_series(1, 50) AS g;

-- 3. Категории
INSERT INTO categories (parent_id, name) VALUES
    (NULL, 'Электроника'),
    (NULL, 'Одежда'),
    (NULL, 'Книги'),
    (NULL, 'Дом и сад'),
    (NULL, 'Спорт');

INSERT INTO categories (parent_id, name)
SELECT (SELECT r.id FROM categories r
        WHERE r.parent_id IS NULL
        ORDER BY r.id
        OFFSET (g - 1) % 5 LIMIT 1),
       'Подкатегория ' || g
FROM generate_series(1, 20) AS g;

-- 4. Товары
INSERT INTO products (seller_id, category_id, title, description, price, is_active, created_at)
SELECT 1 + g % 50,
       (SELECT min(id) FROM categories WHERE parent_id IS NOT NULL) + g % 20,
       (ARRAY['Смартфон','Ноутбук','Футболка','Книга',
              'Кроссовки','Лампа','Рюкзак','Наушники'])[1 + g % 8]
           || ' модель ' || g,
       CASE WHEN g % 7 = 0 THEN NULL ELSE 'Описание товара ' || g END,
       (100 + (g * 7919) % 99900 + (g % 100) / 100.0)::numeric(12,2),
       g % 10 <> 0,
       now() - (g % 365) * interval '1 day'
FROM generate_series(1, 2000) AS g;

-- 5. Складские остатки
INSERT INTO stock (product_id, quantity)
SELECT id, (id * 13) % 200
FROM products;

-- 6. Адреса
INSERT INTO addresses (user_id, city, street, house, apartment)
SELECT 1 + (g - 1) % 1200,
       (ARRAY['Москва','Санкт-Петербург','Казань','Новосибирск','Екатеринбург'])[1 + g % 5],
       'Улица ' || (1 + g % 40),
       (1 + g % 120)::text,
       CASE WHEN g % 3 = 0 THEN NULL ELSE (1 + g % 200)::text END
FROM generate_series(1, 1800) AS g;

-- 7. Корзины
INSERT INTO carts (user_id)
SELECT g FROM generate_series(1, 800) AS g;

-- 8. Позиции корзин
INSERT INTO cart_items (cart_id, product_id, quantity)
SELECT c.id,
       1 + ((c.id * 3 + k) * 7) % 2000,
       1 + (c.id + k) % 3
FROM carts c
CROSS JOIN generate_series(0, 2) AS k;

-- 9. Заказы
INSERT INTO orders (user_id, status, created_at)
SELECT 1 + (g * 7) % 1200,
       (ARRAY['created','paid','shipped','delivered','cancelled'])[1 + g % 5],
       now() - (g % 180) * interval '1 day' - (g % 24) * interval '1 hour'
FROM generate_series(1, 3000) AS g;

-- 10. Позиции заказов
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT o.id, p.id, 1 + (o.id + k) % 4, p.price
FROM orders o
CROSS JOIN generate_series(0, 2) AS k
JOIN products p ON p.id = 1 + (o.id * 11 + k * 101) % 2000
WHERE k <= o.id % 3;

-- Согласование сумм заказов с их позициями
UPDATE orders o
SET total_amount = s.total
FROM (SELECT order_id, SUM(quantity * unit_price) AS total
      FROM order_items
      GROUP BY order_id) AS s
WHERE s.order_id = o.id;

-- 11. Платежи
INSERT INTO payments (order_id, amount, status, paid_at)
SELECT id,
       total_amount,
       CASE status WHEN 'created'   THEN 'pending'
                   WHEN 'cancelled' THEN 'failed'
                   ELSE 'completed' END,
       CASE WHEN status IN ('paid','shipped','delivered')
            THEN created_at + interval '10 minutes' END
FROM orders;

-- 12. Доставки
INSERT INTO deliveries (order_id, address_id, delivery_status, delivery_date)
SELECT o.id,
       (SELECT min(a.id) FROM addresses a WHERE a.user_id = o.user_id),
       CASE o.status WHEN 'paid'    THEN 'processing'
                     WHEN 'shipped' THEN 'in_transit'
                     ELSE 'delivered' END,
       CASE WHEN o.status = 'delivered'
            THEN (o.created_at + interval '3 days')::date END
FROM orders o
WHERE o.status IN ('paid','shipped','delivered');

-- 13. Отзывы
INSERT INTO reviews (user_id, product_id, score, comment)
SELECT 1 + g % 1200,
       1 + (g * 13) % 2000,
       1 + (g * 7) % 5,
       CASE WHEN g % 4 = 0 THEN NULL ELSE 'Отзыв №' || g END
FROM generate_series(1, 2500) AS g;

-- Проверка: количество строк в таблицах
SELECT 'users' AS table_name, count(*) AS rows FROM users
UNION ALL SELECT 'sellers',     count(*) FROM sellers
UNION ALL SELECT 'categories',  count(*) FROM categories
UNION ALL SELECT 'products',    count(*) FROM products
UNION ALL SELECT 'stock',       count(*) FROM stock
UNION ALL SELECT 'addresses',   count(*) FROM addresses
UNION ALL SELECT 'carts',       count(*) FROM carts
UNION ALL SELECT 'cart_items',  count(*) FROM cart_items
UNION ALL SELECT 'orders',      count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'payments',    count(*) FROM payments
UNION ALL SELECT 'deliveries',  count(*) FROM deliveries
UNION ALL SELECT 'reviews',     count(*) FROM reviews;

-- ---------------------------------------------------------------------
-- ЧАСТЬ 2. ЗАПРОСЫ
-- ---------------------------------------------------------------------

-- Запрос 1. DISTINCT и псевдонимы столбцов.
-- Назначение: получить уникальные пары «категория — продавец», по которым
-- есть товары (2000 товаров сворачиваются в 100 уникальных пар).
SELECT DISTINCT
       category_id AS "Категория",
       seller_id   AS "Продавец"
FROM products
ORDER BY category_id, seller_id;

-- Запрос 2. Условия AND / OR со скобками.
-- Назначение: активные товары первых десяти продавцов, которые либо
-- дешёвые (< 2000), либо дорогие (>= 95000).
SELECT id,
       title AS "Название",
       price AS "Цена",
       seller_id AS "Продавец"
FROM products
WHERE is_active = TRUE
  AND seller_id <= 10
  AND (price < 2000 OR price >= 95000)
ORDER BY price;

-- Запрос 3. BETWEEN.
-- Назначение: товары средней ценовой категории, добавленные за последние 30 дней.
SELECT id, title, price, created_at::date AS added_on
FROM products
WHERE price BETWEEN 5000 AND 10000
  AND created_at BETWEEN now() - interval '30 days' AND now()
ORDER BY created_at DESC;

-- Запрос 4. IN.
-- Назначение: заказы, которые находятся на этапе отправки или уже доставлены,
-- и сумма которых не меньше 50000.
SELECT id AS "Заказ",
       user_id AS "Покупатель",
       status AS "Статус",
       total_amount AS "Сумма"
FROM orders
WHERE status IN ('shipped', 'delivered')
  AND total_amount >= 50000
ORDER BY total_amount DESC;

-- Запрос 5а. ILIKE (без учёта регистра) и %.
-- Назначение: найти все товары, название которых начинается со слова «смартфон».
SELECT id, title, price
FROM products
WHERE title ILIKE 'смартфон%'
ORDER BY id;

-- Запрос 5б. LIKE и _ (ровно один произвольный символ).
-- Назначение: товары, у которых номер модели трёхзначный вида 1?5
-- (105, 115, ..., 195).
SELECT id, title
FROM products
WHERE title LIKE '%модель 1_5'
ORDER BY id;

-- Запрос 6а. IS NULL.

SELECT id, title, price
FROM products
WHERE description IS NULL
ORDER BY id;

-- Запрос 6б. IS NOT NULL.
-- Назначение: пользователи, у которых указан телефон, и их телефоны.
SELECT id, full_name, phone
FROM users
WHERE phone IS NOT NULL
ORDER BY id
LIMIT 20;

-- Запрос 7. Сортировка по двум столбцам в разных направлениях.

SELECT category_id AS "Категория",
       title AS "Название",
       price AS "Цена"
FROM products
WHERE is_active
ORDER BY category_id ASC, price DESC
LIMIT 20;

-- Запрос 8. Постраничный вывод (LIMIT / OFFSET), размер страницы 10.
-- Формула: OFFSET = (номер_страницы - 1) * размер_страницы.


-- Страница 1
SELECT id, title, price
FROM products
WHERE is_active
ORDER BY price DESC, id
LIMIT 10 OFFSET 0;

-- Страница 2
SELECT id, title, price
FROM products
WHERE is_active
ORDER BY price DESC, id
LIMIT 10 OFFSET 10;

-- Страница 3
SELECT id, title, price
FROM products
WHERE is_active
ORDER BY price DESC, id
LIMIT 10 OFFSET 20;
