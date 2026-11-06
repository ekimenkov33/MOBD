# Отчёт по лабораторной работе № 3

**Тема:** Многотабличные и аналитические запросы. Представления
**База данных:** маркетплейс (PostgreSQL), структура — ЛР 1, данные — ЛР 2
**Файл со скриптом:** `lr3.sql`

---

## 1. Цель работы

Освоить соединение таблиц (INNER JOIN, LEFT JOIN), группировку и агрегацию (GROUP BY, HAVING), подзапросы (скалярные, IN, EXISTS, коррелированные), общие табличные выражения (в том числе рекурсивные) и научиться оформлять типовые отчёты в виде представлений.

## 2. Используемая схема

| Таблица | Ключевые поля | Связи |
|---|---|---|
| `users` | id, full_name, email, phone | — |
| `sellers` | id, user_id, store_name, description | → users |
| `categories` | id, parent_id, name | самосвязь (дерево) |
| `products` | id, seller_id, category_id, title, price, is_active | → sellers, → categories |
| `stock` | product_id, quantity | → products |
| `carts`, `cart_items` | user_id; cart_id, product_id, quantity | → users, products |
| `orders` | id, user_id, status, total_amount, created_at | → users |
| `order_items` | order_id, product_id, quantity, unit_price | → orders, products |
| `payments` | order_id, amount, status | → orders |
| `deliveries` | order_id, address_id, delivery_status | → orders, addresses |
| `reviews` | user_id, product_id, score, comment | → users, products |

Особенности тестовых данных (важны для интерпретации результатов): товары лежат только в 20 дочерних категориях (по 100 в каждой), у 5 корневых категорий товаров нет; корзины есть у пользователей 1–800; доставки созданы только для заказов в статусах `paid`, `shipped`, `delivered`; отзывы покрывают все 2000 товаров.

---

## 3. Ход работы

### 3.1. INNER JOIN трёх таблиц (товар — категория — продавец)

```sql
SELECT p.id, p.title, p.price,
       c.name AS category, pc.name AS parent_category, s.store_name
FROM products p
JOIN categories c        ON c.id  = p.category_id
LEFT JOIN categories pc  ON pc.id = c.parent_id
JOIN sellers s           ON s.id  = p.seller_id
WHERE p.is_active
ORDER BY pc.name, c.name, p.price DESC
LIMIT 20;
```

Соединение выполняется по внешним ключам: `products.category_id = categories.id` и `products.seller_id = sellers.id`. INNER JOIN оставляет только строки, для которых нашлась пара. Для вывода родительской категории добавлено самосоединение `categories` через LEFT JOIN.

### 3.2. LEFT JOIN — строки без соответствий

Шаблон: левая таблица соединяется с правой, затем `WHERE правая.ключ IS NULL` оставляет только строки без пары.

**а) Товары без отзывов**

```sql
SELECT p.id, p.title, p.price
FROM products p
LEFT JOIN reviews r ON r.product_id = p.id
WHERE r.product_id IS NULL;
```

Результат: **0 строк**. Это ожидаемо — 2500 отзывов покрывают все 2000 товаров. Запрос корректен и пригоден для реальных данных.

**б) Пользователи без корзины** — `users LEFT JOIN carts ... WHERE c.id IS NULL`. Результат: пользователи 801–1200 (400 строк).

**в) Заказы без доставки** — `orders LEFT JOIN deliveries ... WHERE d.order_id IS NULL`. Результат: заказы в статусах `created` и `cancelled` (1200 строк, 40 % заказов).

### 3.3. Группировка и агрегация: число товаров и средняя цена по категориям

```sql
SELECT c.id, c.name,
       count(p.id)            AS products,
       count(*)               AS count_star,
       round(avg(p.price), 2) AS avg_price
FROM categories c
LEFT JOIN products p ON p.category_id = c.id
GROUP BY c.id, c.name
ORDER BY c.id;
```

Результат: 25 строк. У 20 дочерних категорий по 100 товаров; у 5 корневых `count(p.id) = 0`, `avg = NULL`. Столбец `count(*)` для корневых даёт 1 (считается строка с NULL от LEFT JOIN) — наглядная разница между `COUNT(*)` и `COUNT(столбец)`.

### 3.4. HAVING — продавцы с выручкой выше 12 млн

```sql
SELECT s.id, s.store_name,
       count(DISTINCT o.id)             AS orders_cnt,
       sum(oi.quantity * oi.unit_price) AS revenue
FROM sellers s
JOIN products p     ON p.seller_id = s.id
JOIN order_items oi ON oi.product_id = p.id
JOIN orders o       ON o.id = oi.order_id
WHERE o.status <> 'cancelled'
GROUP BY s.id, s.store_name
HAVING sum(oi.quantity * oi.unit_price) > 12000000
ORDER BY revenue DESC;
```

Порядок выполнения: `FROM/JOIN` → `WHERE` (отбрасываем отменённые заказы до группировки) → `GROUP BY` → `HAVING` (фильтр по агрегату — в WHERE агрегат использовать нельзя) → `SELECT` → `ORDER BY`. Порог 12 млн выбран близким к медианной выручке продавца в тестовых данных, поэтому в выборку попадает примерно половина магазинов.

### 3.5. Подзапросы

| Вид | Запрос | Смысл |
|---|---|---|
| Скалярный | `WHERE price > (SELECT avg(price) FROM products)` | товары дороже средней цены каталога; подзапрос возвращает одно значение |
| IN | `WHERE id IN (SELECT ... delivered ...) AND id IN (SELECT ... score = 5)` | товары, которые покупали в доставленных заказах и получили оценку 5 |
| EXISTS | `WHERE EXISTS (SELECT 1 FROM orders o JOIN payments ... WHERE o.user_id = u.id AND pay.status = 'failed')` | пользователи с хотя бы одним неуспешным платежом |
| NOT EXISTS | `WHERE NOT EXISTS (SELECT 1 FROM cart_items ci WHERE ci.product_id = p.id)` | товары, которых нет ни в одной корзине |
| Коррелированный | `WHERE p.price > (SELECT avg(p2.price) FROM products p2 WHERE p2.category_id = p.category_id)` | товары дороже средней цены своей категории; подзапрос пересчитывается для каждой строки внешнего запроса |

Полные тексты — в `lr3.sql`, раздел 5.

### 3.6. CTE

**Обычный CTE** разбивает задачу на шаги: `seller_revenue` (выручка каждого продавца) → `avg_revenue` (средняя выручка) → итоговый запрос выбирает продавцов выше среднего и присваивает ранг функцией `rank() OVER (...)`.

**Рекурсивный CTE** обходит дерево категорий:

```sql
WITH RECURSIVE category_tree AS (
    SELECT id, parent_id, name, id AS root_id, 0 AS level, name::text AS path
    FROM categories WHERE parent_id IS NULL          -- якорь: корни
    UNION ALL
    SELECT c.id, c.parent_id, c.name, t.root_id, t.level + 1,
           t.path || ' > ' || c.name
    FROM categories c
    JOIN category_tree t ON c.parent_id = t.id       -- рекурсивный шаг: потомки
)
SELECT id, level, path FROM category_tree ORDER BY path;
```

Якорная часть выбирает 5 корней (уровень 0), рекурсивная на каждом шаге добавляет потомков найденных строк, пока они есть. Итог — 25 строк вида `Электроника > Подкатегория 1` с уровнями 0 и 1. Приведение `name::text` необходимо, чтобы типы столбцов якоря и рекурсивной части совпали. Вариант 6в использует то же дерево, чтобы посчитать число товаров во всей ветке (корень + потомки): так как товары лежат только в листьях, они «поднимаются» к корневой категории.

### 3.7. Представления

| Представление | Назначение |
|---|---|
| `v_product_catalog` | каталог: товар, категория, продавец, остаток на складе, средняя оценка и число отзывов |
| `v_seller_revenue` | выручка, число заказов и проданных единиц по каждому продавцу (без отменённых заказов) |
| `v_category_branch_stats` | число товаров и средняя цена по веткам категорий (внутри — рекурсивный CTE) |
| `mv_seller_revenue` | материализованное представление над `v_seller_revenue` (дополнительно) |

Обращение к представлениям:

```sql
SELECT product_id, title, price, category, seller, in_stock, avg_score
FROM v_product_catalog
WHERE is_active AND in_stock > 0 AND avg_score >= 3 AND price < 3000
ORDER BY avg_score DESC, price LIMIT 10;

SELECT seller_id, store_name, revenue
FROM v_seller_revenue ORDER BY revenue DESC LIMIT 5;

SELECT * FROM v_category_branch_stats ORDER BY root_id;
```

Преимущества: сложное соединение и агрегация записаны один раз, пользователь работает как с обычной таблицей, логика отчёта изменяется в одном месте.

---

## 4. Выводы

В работе составлены многотабличные запросы с INNER и LEFT JOIN, агрегаты с GROUP BY и HAVING, подзапросы всех видов, обычный и рекурсивный CTE, а также три представления и одно материализованное. LEFT JOIN с проверкой `IS NULL` позволяет находить «пустоты» в данных (пользователи без корзин, заказы без доставки). Рекурсивный CTE решает задачу обхода иерархии произвольной глубины, которую обычным JOIN выразить нельзя. Представления упрощают повторяющиеся отчёты.

---

## 5. Ответы на контрольные вопросы

**1. Что такое соединение таблиц и по какому условию оно выполняется?**
Соединение (JOIN) объединяет строки двух таблиц в одну результирующую строку. Обычно условие — равенство внешнего ключа одной таблицы и первичного ключа другой (`products.seller_id = sellers.id`).

**2. Чем INNER JOIN отличается от LEFT JOIN?**
INNER JOIN возвращает только строки, для которых есть совпадение в обеих таблицах. LEFT JOIN сохраняет все строки левой таблицы, а недостающие столбцы правой заполняет NULL. LEFT JOIN нужен, например, чтобы найти товары без отзывов или пользователей без заказов — INNER JOIN такие строки отбросил бы.

**3. Какие агрегатные функции вы знаете? Разница между COUNT(\*) и COUNT(столбец)?**
`COUNT`, `SUM`, `AVG`, `MIN`, `MAX` (а также `string_agg`, `array_agg` и др.). `COUNT(*)` считает все строки группы, `COUNT(столбец)` — только строки, где значение столбца не NULL. `COUNT(DISTINCT столбец)` считает уникальные значения.

**4. Для чего GROUP BY и что допустимо в списке выборки?**
GROUP BY объединяет строки с одинаковыми значениями указанных столбцов в группы, к которым применяются агрегаты. В SELECT допустимы столбцы из GROUP BY, агрегатные функции и константы/выражения над ними.

**5. Чем WHERE отличается от HAVING, в каком порядке выполняются?**
WHERE фильтрует исходные строки до группировки и не может содержать агрегатов; HAVING фильтрует группы после GROUP BY и работает с агрегатами. Порядок: FROM/JOIN → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → LIMIT.

**6. Что такое подзапрос? Коррелированный и некоррелированный?**
Подзапрос — запрос внутри другого запроса. Некоррелированный не зависит от внешнего и выполняется один раз (`avg(price)` по всей таблице). Коррелированный ссылается на столбцы внешнего запроса и логически выполняется для каждой его строки (средняя цена *своей* категории).

**7. Как работает EXISTS и когда удобен?**
`EXISTS (подзапрос)` возвращает TRUE, если подзапрос вернул хотя бы одну строку; сами значения не важны (обычно пишут `SELECT 1`). Удобен для проверки «есть ли связанные записи» и, в форме `NOT EXISTS`, «нет ли». Он останавливается на первой найденной строке и корректно работает с NULL, в отличие от `NOT IN`.

**8. Что такое CTE и зачем рекурсивный CTE?**
CTE (`WITH имя AS (...)`) — именованный временный результат запроса, существующий в рамках одного оператора; делает сложный запрос читаемым, разбивая его на шаги. Рекурсивный CTE (`WITH RECURSIVE`) состоит из якорной части и рекурсивной, соединённых `UNION ALL`, и нужен для обхода иерархий и графов — дерева категорий, оргструктуры.

**9. Что такое представление? Хранит ли данные?**
Представление (VIEW) — сохранённый именованный запрос, «виртуальная таблица». Обычное представление данных не хранит: запрос выполняется заново при каждом обращении, поэтому данные всегда актуальны.

**10. Чем материализованное представление отличается от обычного?**
Материализованное физически хранит результат запроса на диске, поэтому читается быстро, но данные устаревают и обновляются вручную командой `REFRESH MATERIALIZED VIEW`. Подходит для тяжёлых отчётов, которые не требуют абсолютной актуальности.
