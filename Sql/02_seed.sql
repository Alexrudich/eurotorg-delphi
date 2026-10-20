/* ============================================================================
   02_seed.sql  —  тестовые данные для проверки «остатков на дату»

   Запускать ПОСЛЕ 01_schema.sql.
   Идемпотентен: данные пересоздаются, схемы не трогаются.

   Сценарий:
     5 приходов -> 1 перемещение с расщеплением партии -> 1 расход по FIFO.
   Итог: 6 партий, 9 движений.

   Про IDENTITY_INSERT.
   В SQL Server этот режим включается одновременно только для ОДНОЙ таблицы.
   Попытка держать его включённым и для Batch, и для StockMovement обрывает
   батч ошибкой 8107. Поэтому:
     - BatchId задаём явно (на него смотрят внешние ключи и проверки ниже);
     - MovementId сервер генерирует сам, он никому не нужен как ссылка.
   ============================================================================ */

USE WarehouseDB;
GO

IF OBJECT_ID(N'dbo.StockMovement') IS NULL
    THROW 50002, N'Схема не создана. Сначала выполни 01_schema.sql.', 1;
GO

/* --- 1. Очистка -----------------------------------------------------------
   Порядок обратный зависимостям, иначе FK не даст удалить. */

DELETE FROM dbo.StockMovement;
DELETE FROM dbo.DocumentLine;
DELETE FROM dbo.Document;
DELETE FROM dbo.Batch;
DELETE FROM dbo.Place;
DELETE FROM dbo.Warehouse;
DELETE FROM dbo.Goods;
GO

/* --- 2. Справочники ------------------------------------------------------- */

SET IDENTITY_INSERT dbo.Goods ON;
INSERT INTO dbo.Goods (GoodsId, GoodsName) VALUES
    (1, N'Молоко 3.2%'),
    (2, N'Хлеб белый'),
    (3, N'Сметана 20%');
SET IDENTITY_INSERT dbo.Goods OFF;
GO

SET IDENTITY_INSERT dbo.Warehouse ON;
INSERT INTO dbo.Warehouse (WarehouseId, WarehouseName) VALUES
    (1, N'Склад «Центральный»'),
    (2, N'Склад «Северный»');
SET IDENTITY_INSERT dbo.Warehouse OFF;
GO

SET IDENTITY_INSERT dbo.Place ON;
INSERT INTO dbo.Place (PlaceId, WarehouseId, PlaceName) VALUES
    (1, 1, N'А-1-1'),
    (2, 1, N'А-1-2'),
    (3, 2, N'Б-2-1'),
    (4, 2, N'Б-2-2');
SET IDENTITY_INSERT dbo.Place OFF;
GO

/* --- 3. Приходы: партии ---------------------------------------------------
   Price принадлежит ПАРТИИ, поэтому один товар может лежать по разным ценам.
   Quantity вставляется сразу итоговым — никаких UPDATE следом. */

SET IDENTITY_INSERT dbo.Batch ON;

-- Партия 1: Молоко, 100 шт по 120.50, Центральный А-1-1, 01.10.
INSERT INTO dbo.Batch (BatchId, GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate)
VALUES (1, 1, 1, 0.000, 120.50, '2026-10-01 09:00:00', '2026-11-01 09:00:00');

-- Партия 2: Хлеб, 200 шт по 65.00, Центральный А-1-2, 01.10. ExpiryDate = NULL.
INSERT INTO dbo.Batch (BatchId, GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate)
VALUES (2, 2, 2, 200.000, 65.00, '2026-10-01 10:00:00', NULL);

-- Партия 3: Молоко, 50 шт по 118.00, Северный Б-2-1, 05.10.
-- Дешевле и позже партии 1 -> вторая в очереди FIFO.
INSERT INTO dbo.Batch (BatchId, GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate)
VALUES (3, 1, 3, 0.000, 118.00, '2026-10-05 14:00:00', '2026-11-05 14:00:00');

-- Партия 4: Сметана, 80 шт по 210.00, Северный Б-2-2, 07.10.
-- Её частично переместим -> расщепление.
INSERT INTO dbo.Batch (BatchId, GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate)
VALUES (4, 3, 4, 50.000, 210.00, '2026-10-07 08:00:00', '2026-10-20 08:00:00');

-- Партия 5: Сметана, 40 шт по 205.00, Центральный А-1-1, 08.10.
-- Отдельная партия, а не пополнение партии 4: другая цена и другое место.
INSERT INTO dbo.Batch (BatchId, GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate)
VALUES (5, 3, 1, 40.000, 205.00, '2026-10-08 11:00:00', '2026-10-22 11:00:00');

-- Партия 6: остаток партии 4 после переезда 30 шт на Центральный.
-- Тот же товар, цена, IncomeDate и ExpiryDate — другое место.
INSERT INTO dbo.Batch (BatchId, GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate)
VALUES (6, 3, 1, 30.000, 210.00, '2026-10-07 08:00:00', '2026-10-20 08:00:00');

SET IDENTITY_INSERT dbo.Batch OFF;
GO

/* --- 4. Движения ----------------------------------------------------------
   MovementId генерируется сервером. Порядок вставки = порядок идентификаторов,
   поэтому в журнале они идут по возрастанию даты. */

-- Приходы (+)
INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate) VALUES
    (1, 1,  100.000, '2026-10-01 09:00:00'),
    (2, 2,  200.000, '2026-10-01 10:00:00'),
    (3, 3,   50.000, '2026-10-05 14:00:00'),
    (4, 4,   80.000, '2026-10-07 08:00:00'),
    (5, 1,   40.000, '2026-10-08 11:00:00');

-- Перемещение 30 шт сметаны: минус со Северного, плюс на Центральный.
INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate) VALUES
    (4, 4,  -30.000, '2026-10-09 10:00:00'),
    (6, 1,   30.000, '2026-10-09 10:00:00');

-- Расход 150 шт молока по FIFO: сначала партия 1 (01.10), затем партия 3 (05.10).
INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate) VALUES
    (1, 1, -100.000, '2026-10-09 12:00:00'),
    (3, 3,  -50.000, '2026-10-09 12:00:00');
GO

/* ============================================================================
   ПРОВЕРКИ
   ============================================================================ */

PRINT N'=== 1. Партии (ожидаем 6 строк) ===';
SELECT b.BatchId, g.GoodsName, w.WarehouseName, p.PlaceName,
       b.Quantity, b.Price, b.IncomeDate, b.ExpiryDate
FROM dbo.Batch AS b
    INNER JOIN dbo.Goods     AS g ON g.GoodsId     = b.GoodsId
    INNER JOIN dbo.Place     AS p ON p.PlaceId     = b.PlaceId
    INNER JOIN dbo.Warehouse AS w ON w.WarehouseId = p.WarehouseId
ORDER BY b.IncomeDate, b.BatchId;
GO

PRINT N'=== 2. Сверка кэша Batch.Quantity с журналом (ожидаем 0 строк) ===';
SELECT b.BatchId, g.GoodsName, p.PlaceName,
       b.Quantity AS CacheQty, ISNULL(SUM(m.Quantity), 0) AS JournalQty
FROM dbo.Batch AS b
    INNER JOIN dbo.Goods AS g ON g.GoodsId = b.GoodsId
    INNER JOIN dbo.Place AS p ON p.PlaceId = b.PlaceId
    LEFT JOIN dbo.StockMovement AS m ON m.BatchId = b.BatchId
GROUP BY b.BatchId, g.GoodsName, p.PlaceName, b.Quantity
HAVING ISNULL(SUM(m.Quantity), 0) <> b.Quantity;
GO

PRINT N'=== 3a. На 02.10.2026 00:00 (ожидаем 2 строки) ===';
EXEC dbo.usp_StockOnDate @Target = '2026-10-02 00:00:00';
GO

PRINT N'=== 3b. На 06.10.2026 00:00 (ожидаем 3 строки) ===';
EXEC dbo.usp_StockOnDate @Target = '2026-10-06 00:00:00';
GO

PRINT N'=== 3c. На 08.10.2026 23:59 (ожидаем 5 строк) ===';
EXEC dbo.usp_StockOnDate @Target = '2026-10-08 23:59:00';
GO

PRINT N'=== 3d. На 09.10.2026 12:30 (ожидаем 4 строки, молока нет) ===';
EXEC dbo.usp_StockOnDate @Target = '2026-10-09 12:30:00';
GO

PRINT N'=== 4. Итоговые остатки по товарам (справка) ===';
SELECT g.GoodsName, SUM(m.Quantity) AS QtyTotal
FROM dbo.StockMovement AS m
    INNER JOIN dbo.Batch AS b ON b.BatchId = m.BatchId
    INNER JOIN dbo.Goods AS g ON g.GoodsId = b.GoodsId
GROUP BY g.GoodsName
ORDER BY g.GoodsName;
GO