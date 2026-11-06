-- =====================================================================
-- ЛР 3. Многотабличные и аналитические запросы, представления
-- Предварительно выполнены скрипты ЛР 1 (таблицы) и ЛР 2 (данные).
-- СУБД: PostgreSQL.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. INNER JOIN трёх таблиц: товар — категория — продавец
--    (дополнительно LEFT JOIN к родительской категории: у корневых
--    категорий parent_id = NULL, но товары лежат в дочерних).
-- ---------------------------------------------------------------------
SELECT p.id           AS "ID товара",
       p.title        AS "Товар",
       p.price        AS "Цена",
       c.name         AS "Категория",
       pc.name        AS "Родительская категория",
       s.store_name   AS "Магазин"
FROM products p
JOIN categories c        ON c.id  = p.category_id
LEFT JOIN categories pc  ON pc.id = c.parent_id
JOIN sellers s           ON s.id  = p.seller_id
WHERE p.is_active
ORDER BY pc.name, c.name, p.price DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- 2. LEFT JOIN: строки без соответствий в связанной таблице
-- ---------------------------------------------------------------------

-- 2а. Товары без отзывов (пример из задания).
--     На данных ЛР 2 результат пуст: 2500 отзывов покрывают все 2000 товаров.
SELECT p.id, p.title, p.price
FROM products p
LEFT JOIN reviews r ON r.product_id = p.id
WHERE r.product_id IS NULL
ORDER BY p.id;

-- 2б. Пользователи без корзины (корзины есть только у пользователей 1..800).
SELECT u.id, u.full_name, u.email
FROM users u
LEFT JOIN carts c ON c.user_id = u.id
WHERE c.id IS NULL
ORDER BY u.id
LIMIT 20;

-- 2в. Заказы без доставки (статусы created и cancelled).
SELECT o.id AS "Заказ", o.status AS "Статус", o.total_amount AS "Сумма"
FROM orders o
LEFT JOIN deliveries d ON d.order_id = o.id
WHERE d.order_id IS NULL
ORDER BY o.id
LIMIT 20;

-- ---------------------------------------------------------------------
-- 3. GROUP BY и агрегаты: по каждой категории — число товаров и средняя цена
--    LEFT JOIN сохраняет и корневые категории (у них товаров нет).
--    count(p.id) = 0 для них, а count(*) дал бы 1 — наглядная разница.
-- ---------------------------------------------------------------------
SELECT c.id                         AS "ID",
       c.name                       AS "Категория",
       count(p.id)                  AS "Товаров",
       count(*)                     AS "count(*) для сравнения",
       round(avg(p.price), 2)       AS "Средняя цена",
       min(p.price)                 AS "Мин. цена",
       max(p.price)                 AS "Макс. цена"
FROM categories c
LEFT JOIN products p ON p.category_id = c.id
GROUP BY c.id, c.name
ORDER BY c.id;

-- ---------------------------------------------------------------------
-- 4. HAVING: продавцы с выручкой выше 12 000 000
--    WHERE отсекает отменённые заказы ДО группировки,
--    HAVING фильтрует уже готовые группы по агрегату.
-- ---------------------------------------------------------------------
SELECT s.id                                   AS "ID",
       s.store_name                           AS "Магазин",
       count(DISTINCT o.id)                   AS "Заказов",
       sum(oi.quantity * oi.unit_price)       AS "Выручка"
FROM sellers s
JOIN products p     ON p.seller_id  = s.id
JOIN order_items oi ON oi.product_id = p.id
JOIN orders o       ON o.id = oi.order_id
WHERE o.status <> 'cancelled'
GROUP BY s.id, s.store_name
HAVING sum(oi.quantity * oi.unit_price) > 12000000
ORDER BY "Выручка" DESC;

-- ---------------------------------------------------------------------
-- 5. Подзапросы
-- ---------------------------------------------------------------------

-- 5а. Скалярный: товары дороже средней цены по всему каталогу.
SELECT id, title, price,
       round(price - (SELECT avg(price) FROM products), 2) AS "Выше средней на"
FROM products
WHERE price > (SELECT avg(price) FROM products)
ORDER BY price DESC
LIMIT 10;

-- 5б. IN: товары, которые покупали в доставленных заказах и которые
--     получили хотя бы одну оценку 5.
SELECT id, title, price
FROM products
WHERE id IN (SELECT oi.product_id
             FROM order_items oi
             JOIN orders o ON o.id = oi.order_id
             WHERE o.status = 'delivered')
  AND id IN (SELECT product_id FROM reviews WHERE score = 5)
ORDER BY id
LIMIT 20;

-- 5в. EXISTS: пользователи, у которых есть хотя бы один неуспешный платёж.
SELECT u.id, u.full_name
FROM users u
WHERE EXISTS (SELECT 1
              FROM orders o
              JOIN payments pay ON pay.order_id = o.id
              WHERE o.user_id = u.id
                AND pay.status = 'failed')
ORDER BY u.id
LIMIT 20;

-- 5г. NOT EXISTS: товары, которых нет ни в одной корзине.
SELECT p.id, p.title
FROM products p
WHERE NOT EXISTS (SELECT 1 FROM cart_items ci WHERE ci.product_id = p.id)
ORDER BY p.id
LIMIT 20;

-- 5д. Коррелированный: товары дороже средней цены СВОЕЙ категории.
SELECT p.id, p.title, p.category_id, p.price
FROM products p
WHERE p.price > (SELECT avg(p2.price)
                 FROM products p2
                 WHERE p2.category_id = p.category_id)
ORDER BY p.category_id, p.price DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- 6. CTE
-- ---------------------------------------------------------------------

-- 6а. Обычный CTE в несколько шагов: выручка продавцов -> средняя выручка
--     -> продавцы выше среднего с рангом.
WITH seller_revenue AS (
    SELECT s.id, s.store_name,
           sum(oi.quantity * oi.unit_price) AS revenue
    FROM sellers s
    JOIN products p     ON p.seller_id   = s.id
    JOIN order_items oi ON oi.product_id = p.id
    JOIN orders o       ON o.id = oi.order_id
    WHERE o.status <> 'cancelled'
    GROUP BY s.id, s.store_name
),
avg_revenue AS (
    SELECT avg(revenue) AS avg_rev FROM seller_revenue
)
SELECT sr.id, sr.store_name,
       sr.revenue,
       round(sr.revenue - a.avg_rev, 2)      AS "Выше среднего на",
       rank() OVER (ORDER BY sr.revenue DESC) AS "Место"
FROM seller_revenue sr
CROSS JOIN avg_revenue a
WHERE sr.revenue > a.avg_rev
ORDER BY sr.revenue DESC
LIMIT 10;

-- 6б. Рекурсивный CTE: обход дерева категорий (путь и уровень вложенности).
WITH RECURSIVE category_tree AS (
    SELECT id, parent_id, name,
           id            AS root_id,
           0             AS level,
           name::text    AS path
    FROM categories
    WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, c.name,
           t.root_id,
           t.level + 1,
           t.path || ' > ' || c.name
    FROM categories c
    JOIN category_tree t ON c.parent_id = t.id
)
SELECT id, level, path
FROM category_tree
ORDER BY path;

-- 6в. Рекурсивный CTE + агрегация: сколько товаров в каждой ВЕТКЕ
--     (корневая категория вместе со всеми потомками).
WITH RECURSIVE category_tree AS (
    SELECT id, id AS root_id FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, t.root_id
    FROM categories c
    JOIN category_tree t ON c.parent_id = t.id
)
SELECT r.name                    AS "Корневая категория",
       count(p.id)               AS "Товаров в ветке",
       round(avg(p.price), 2)    AS "Средняя цена"
FROM category_tree t
JOIN categories r      ON r.id = t.root_id
LEFT JOIN products p   ON p.category_id = t.id
GROUP BY r.id, r.name
ORDER BY r.id;

-- ---------------------------------------------------------------------
-- 7. Представления
-- ---------------------------------------------------------------------

-- 7.1. Каталог товаров: товар + категория + продавец + остаток + рейтинг.
CREATE OR REPLACE VIEW v_product_catalog AS
SELECT p.id            AS product_id,
       p.title,
       p.price,
       p.is_active,
       c.name          AS category,
       s.store_name    AS seller,
       COALESCE(st.quantity, 0)  AS in_stock,
       r.avg_score,
       COALESCE(r.reviews_count, 0) AS reviews_count
FROM products p
JOIN categories c       ON c.id = p.category_id
JOIN sellers s          ON s.id = p.seller_id
LEFT JOIN stock st      ON st.product_id = p.id
LEFT JOIN (SELECT product_id,
                  round(avg(score), 2) AS avg_score,
                  count(*)             AS reviews_count
           FROM reviews
           GROUP BY product_id) r ON r.product_id = p.id;

-- 7.2. Выручка продавцов (без отменённых заказов).
CREATE OR REPLACE VIEW v_seller_revenue AS
SELECT s.id          AS seller_id,
       s.store_name,
       count(DISTINCT o.id)             AS orders_count,
       sum(oi.quantity)                 AS items_sold,
       sum(oi.quantity * oi.unit_price) AS revenue
FROM sellers s
JOIN products p     ON p.seller_id   = s.id
JOIN order_items oi ON oi.product_id = p.id
JOIN orders o       ON o.id = oi.order_id
WHERE o.status <> 'cancelled'
GROUP BY s.id, s.store_name;

-- 7.3. Статистика по веткам категорий (представление с рекурсивным CTE).
CREATE OR REPLACE VIEW v_category_branch_stats AS
WITH RECURSIVE category_tree AS (
    SELECT id, id AS root_id FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, t.root_id
    FROM categories c
    JOIN category_tree t ON c.parent_id = t.id
)
SELECT r.id                   AS root_id,
       r.name                 AS root_category,
       count(p.id)            AS products_count,
       round(avg(p.price), 2) AS avg_price
FROM category_tree t
JOIN categories r    ON r.id = t.root_id
LEFT JOIN products p ON p.category_id = t.id
GROUP BY r.id, r.name;

-- 7.4. (Дополнительно) Материализованное представление: хранит данные,
--      обновляется вручную командой REFRESH.
DROP MATERIALIZED VIEW IF EXISTS mv_seller_revenue;
CREATE MATERIALIZED VIEW mv_seller_revenue AS
SELECT * FROM v_seller_revenue;

-- ---- Обращение к представлениям ----

-- Дешёвые активные товары с хорошим рейтингом и наличием
SELECT product_id, title, price, category, seller, in_stock, avg_score
FROM v_product_catalog
WHERE is_active AND in_stock > 0 AND avg_score >= 3 AND price < 3000
ORDER BY avg_score DESC, price
LIMIT 10;

-- Топ-5 продавцов по выручке
SELECT seller_id, store_name, orders_count, items_sold, revenue
FROM v_seller_revenue
ORDER BY revenue DESC
LIMIT 5;

-- Ветки категорий
SELECT * FROM v_category_branch_stats ORDER BY root_id;

-- Представление в соединении с таблицей: выручка продавца и его описание
SELECT v.store_name, v.revenue, s.description
FROM v_seller_revenue v
JOIN sellers s ON s.id = v.seller_id
WHERE s.description IS NULL
ORDER BY v.revenue DESC;

-- Материализованное: читается мгновенно, но «замораживает» данные
SELECT * FROM mv_seller_revenue ORDER BY revenue DESC LIMIT 5;
REFRESH MATERIALIZED VIEW mv_seller_revenue;   -- обновить после изменения данных
