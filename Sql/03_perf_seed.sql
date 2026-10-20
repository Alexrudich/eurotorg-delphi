/* ============================================================================
   03_perf_seed.sql — генератор НАГРУЗОЧНЫХ данных для замера производительности

   Создаёт ОТДЕЛЬНУЮ базу WarehousePerfTest: рабочая WarehouseDB не трогается.
   Удаление всех тестовых данных — одна команда DROP DATABASE (низ файла).

   Запуск:
     sqlcmd -S localhost\SQLEXPRESS -E -C -i Sql\03_perf_seed.sql
     sqlcmd -S localhost\SQLEXPRESS -E -C -v BATCHES=700000 -i Sql\03_perf_seed.sql

   BATCHES — число партий; без -v берётся 70 000 (~100k движений).
   Для ~1M движений: BATCHES=700000.

   Состав данных (SET-based вставки, без курсоров и циклов):
     5 000 товаров, 5 складов, 50 мест, @Batches партий.
     На каждую партию — приход (+ движение и документ);
     на 40% партий — ещё расход (− движение и документ).
     Движений ≈ 1.4 × @Batches.

   Приём с IDENTITY_INSERT как в 02_seed.sql: BatchId/DocumentId задаём
   арифметикой от номера строки, связи строятся без SCOPE_IDENTITY.
   ============================================================================ */

USE master;
GO

IF DB_ID(N'WarehousePerfTest') IS NOT NULL
BEGIN
    ALTER DATABASE WarehousePerfTest SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE WarehousePerfTest;
END
GO

CREATE DATABASE WarehousePerfTest;
ALTER DATABASE WarehousePerfTest SET RECOVERY SIMPLE;   -- не раздуваем лог при массовой вставке
GO

USE WarehousePerfTest;
GO

/* --- 1. Схема: точная копия 01_schema.sql --------------------------------- */

CREATE TABLE dbo.Goods
(
    GoodsId   BIGINT IDENTITY(1,1) NOT NULL,
    GoodsName NVARCHAR(100)        NOT NULL,
    CONSTRAINT PK_Goods PRIMARY KEY (GoodsId),
    CONSTRAINT UQ_Goods_Name UNIQUE (GoodsName)
);

CREATE TABLE dbo.Warehouse
(
    WarehouseId   BIGINT IDENTITY(1,1) NOT NULL,
    WarehouseName NVARCHAR(100)        NOT NULL,
    CONSTRAINT PK_Warehouse PRIMARY KEY (WarehouseId)
);

CREATE TABLE dbo.Place
(
    PlaceId     BIGINT IDENTITY(1,1) NOT NULL,
    WarehouseId BIGINT               NOT NULL,
    PlaceName   NVARCHAR(100)        NOT NULL,
    CONSTRAINT PK_Place PRIMARY KEY (PlaceId),
    CONSTRAINT FK_Place_Warehouse FOREIGN KEY (WarehouseId) REFERENCES dbo.Warehouse (WarehouseId)
);

CREATE TABLE dbo.Batch
(
    BatchId    BIGINT IDENTITY(1,1) NOT NULL,
    GoodsId    BIGINT               NOT NULL,
    PlaceId    BIGINT               NOT NULL,
    Quantity   DECIMAL(18,3)        NOT NULL,
    Price      DECIMAL(18,2)        NOT NULL,
    IncomeDate DATETIME2            NOT NULL,
    ExpiryDate DATETIME2            NULL,
    CONSTRAINT PK_Batch PRIMARY KEY (BatchId),
    CONSTRAINT FK_Batch_Goods FOREIGN KEY (GoodsId) REFERENCES dbo.Goods (GoodsId),
    CONSTRAINT FK_Batch_Place FOREIGN KEY (PlaceId) REFERENCES dbo.Place (PlaceId),
    CONSTRAINT CK_Batch_Quantity CHECK (Quantity >= 0)
);

CREATE TABLE dbo.Document
(
    DocumentId BIGINT IDENTITY(1,1) NOT NULL,
    DocType    TINYINT              NOT NULL,
    DocDate    DATETIME2            NOT NULL,
    [Comment]  NVARCHAR(255)        NULL,
    CONSTRAINT PK_Document PRIMARY KEY (DocumentId),
    CONSTRAINT CK_Document_DocType CHECK (DocType IN (1, 2, 3))
);

CREATE TABLE dbo.DocumentLine
(
    LineId      BIGINT IDENTITY(1,1) NOT NULL,
    DocumentId  BIGINT               NOT NULL,
    BatchId     BIGINT               NULL,
    GoodsId     BIGINT               NOT NULL,
    PlaceFromId BIGINT               NULL,
    PlaceToId   BIGINT               NULL,
    Quantity    DECIMAL(18,3)        NOT NULL,
    Price       DECIMAL(18,2)        NULL,
    CONSTRAINT PK_DocumentLine PRIMARY KEY (LineId),
    CONSTRAINT FK_Line_Document FOREIGN KEY (DocumentId) REFERENCES dbo.Document (DocumentId),
    CONSTRAINT CK_DocumentLine_Quantity CHECK (Quantity > 0)
);

CREATE TABLE dbo.StockMovement
(
    MovementId   BIGINT IDENTITY(1,1) NOT NULL,
    BatchId      BIGINT               NOT NULL,
    PlaceId      BIGINT               NOT NULL,
    Quantity     DECIMAL(18,3)        NOT NULL,
    MovementDate DATETIME2            NOT NULL,
    DocumentId   BIGINT               NULL,
    CONSTRAINT PK_StockMovement PRIMARY KEY (MovementId),
    CONSTRAINT FK_Mov_Batch FOREIGN KEY (BatchId) REFERENCES dbo.Batch (BatchId),
    CONSTRAINT FK_Mov_Place FOREIGN KEY (PlaceId) REFERENCES dbo.Place (PlaceId),
    CONSTRAINT CK_StockMovement_Quantity CHECK (Quantity <> 0)
);

CREATE INDEX IX_Mov_BatchPlace_Date ON dbo.StockMovement (BatchId, PlaceId, MovementDate);
CREATE INDEX IX_Batch_Goods_IncomeDate ON dbo.Batch (GoodsId, IncomeDate);
CREATE INDEX IX_Place_Warehouse ON dbo.Place (WarehouseId);
CREATE INDEX IX_Mov_Date_Covering ON dbo.StockMovement (MovementDate)
    INCLUDE (BatchId, PlaceId, Quantity);
GO

CREATE PROCEDURE dbo.usp_StockOnDate
    @Target DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    SELECT g.GoodsName, b.BatchId, w.WarehouseName, p.PlaceName,
           b.IncomeDate, b.ExpiryDate, b.Price,
           SUM(m.Quantity) AS Qty, SUM(m.Quantity) * b.Price AS Sum
    FROM dbo.StockMovement AS m
        INNER JOIN dbo.Batch AS b ON b.BatchId = m.BatchId
        INNER JOIN dbo.Goods AS g ON g.GoodsId = b.GoodsId
        INNER JOIN dbo.Place AS p ON p.PlaceId = m.PlaceId
        INNER JOIN dbo.Warehouse AS w ON w.WarehouseId = p.WarehouseId
    WHERE m.MovementDate <= @Target
    GROUP BY g.GoodsName, b.BatchId, w.WarehouseName, p.PlaceName,
             b.IncomeDate, b.ExpiryDate, b.Price
    HAVING SUM(m.Quantity) <> 0
    ORDER BY g.GoodsName, b.IncomeDate;
END
GO

/* --- 2. Справочники --------------------------------------------------------
   Goods и Place — IDENTITY AUTO, SET IDENTITY_INSERT НЕ НУЖЕН.
   Только Batch/Document требуют ручных ID для детерминированных связей. */

;WITH N AS (SELECT TOP 5000 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n
            FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b)
INSERT INTO dbo.Goods (GoodsName)
SELECT N'Товар_' + FORMAT(n, '00000') FROM N;

INSERT INTO dbo.Warehouse (WarehouseName)
VALUES (N'Склад-01'), (N'Склад-02'), (N'Склад-03'), (N'Склад-04'), (N'Склад-05');

;WITH N AS (SELECT TOP 50 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n
            FROM sys.all_columns)
INSERT INTO dbo.Place (WarehouseId, PlaceName)
SELECT 1 + n % 5, N'М-' + FORMAT(n, '00') FROM N;
GO

/* --- 3. Партии, документы, движения, строки --------------------------------
   Всё считается от rn (номер партии). Псевдослучайность — арифметика от rn,
   детерминированная: одна и та же партия всегда даёт одинаковые qty/price.
   Расход задан на партия rn % 5 < 2 (40%), половина от прихода.
   Порядок вставок: Batch -> Document -> StockMovement -> DocumentLine,
   каждая следующая опирается уже на существующие строки. */

DECLARE @Batches INT;
BEGIN TRY
    -- Без -v BATCHES=... подстановка не происходит, CAST падает — берём 70k.
    SET @Batches = CAST(N'$(BATCHES)' AS INT);
END TRY
BEGIN CATCH
    SET @Batches = 70000;
END CATCH
IF @Batches < 1 OR @Batches > 1000000 SET @Batches = 70000;

DECLARE @Goods INT = 5000, @Places INT = 50;

-- Нумератор до 10^6 строк кросс-джойнами производных таблиц.
-- ВАЖНО: WITH cte AS (VALUES ...) — недопустимый синтаксис SQL Server,
-- табличный конструктор VALUES разрешён только внутри FROM.
-- Семь таблиц по 10 = 10^7 строк: с запасом покрывает верхний лимит @Batches.
-- Пять таблиц (10^5) дали ровно 100 000 партий — потолок проявился как
-- «запросил 700k, получил 100k» без единой ошибки.
WITH N4(n) AS (
    SELECT 1 FROM
        (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS a1(n) CROSS JOIN
        (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS a2(n) CROSS JOIN
        (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS a3(n) CROSS JOIN
        (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS a4(n) CROSS JOIN
        (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS a5(n) CROSS JOIN
        (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS a6(n) CROSS JOIN
        (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS a7(n)
)
SELECT TOP (@Batches)
    rn  = ROW_NUMBER() OVER (ORDER BY (SELECT 1)),
    g   = 0, pl = 0,
    qty = CAST(1 + (ROW_NUMBER() OVER (ORDER BY (SELECT 1)) * 7919) % 200 AS DECIMAL(18,3)),
    prc = CAST(50 + (ROW_NUMBER() OVER (ORDER BY (SELECT 1)) * 104729) % 950 AS DECIMAL(18,2))
INTO #seed
FROM N4;

-- Товар и место — равномерные остатки от rn: без «случайных» колонок
-- распределение воспроизводимо, а нагрузка на индексы реалистична.
UPDATE #seed SET g = 1 + (rn - 1) % 5000, pl = 1 + (rn * 7919) % 50;

ALTER TABLE #seed ADD
    inc  DATETIME2      NOT NULL DEFAULT DATEADD(MINUTE, 0, '2026-07-21 12:00:00'),
    outq DECIMAL(18,3)  NOT NULL DEFAULT 0;

-- Дата прихода: партии размазаны по 90 дням до 2026-10-19 12:00.
-- Расход: 40% партий (rn % 5 < 2) уходят в количестве половины прихода.
UPDATE #seed
SET inc  = DATEADD(MINUTE, -(rn % 129600), CAST('2026-10-19 12:00:00' AS DATETIME2)),
    outq = CASE WHEN rn % 5 < 2 THEN CAST(qty / 2 AS DECIMAL(18,3)) ELSE 0 END;

CREATE UNIQUE INDEX IX_seed_rn ON #seed (rn);

-- 3.1 Партии: Quantity = КЭШ итогового остатка (приход минус расход).
SET IDENTITY_INSERT dbo.Batch ON;
INSERT INTO dbo.Batch (BatchId, GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate)
SELECT rn, g, pl, qty - outq, prc, inc,
       CASE WHEN rn % 3 = 0 THEN DATEADD(DAY, 30, inc) ELSE NULL END
FROM #seed;
SET IDENTITY_INSERT dbo.Batch OFF;

-- 3.2 Документы: приходы DocumentId = rn; расходы = @Batches + порядковый.
SET IDENTITY_INSERT dbo.Document ON;

INSERT INTO dbo.Document (DocumentId, DocType, DocDate, [Comment])
SELECT rn, 1, inc, N'Приход (perf-тест)' FROM #seed;

INSERT INTO dbo.Document (DocumentId, DocType, DocDate, [Comment])
SELECT @Batches + ROW_NUMBER() OVER (ORDER BY rn), 3,
       DATEADD(DAY, 10, inc), N'Расход (perf-тест)'
FROM #seed
WHERE outq > 0;

SET IDENTITY_INSERT dbo.Document OFF;

-- 3.3 Движения: приход (+qty) для всех; расход (−outq) для 40%.
--     Номер расходного документа повторяет 3.2: тот же фильтр и тот же
--     порядок ROW_NUMBER по rn — идентификаторы совпадают детерминированно.
INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate, DocumentId)
SELECT rn, pl, qty, inc, rn FROM #seed;

INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate, DocumentId)
SELECT rn, pl, -outq, DATEADD(DAY, 10, inc),
       @Batches + ROW_NUMBER() OVER (ORDER BY rn)
FROM #seed
WHERE outq > 0;

-- 3.4 Строки документов из уже готовых движений.
INSERT INTO dbo.DocumentLine (DocumentId, BatchId, GoodsId, PlaceToId, Quantity, Price)
SELECT m.DocumentId, m.BatchId, b.GoodsId, m.PlaceId, m.Quantity, b.Price
FROM dbo.StockMovement m JOIN dbo.Batch b ON b.BatchId = m.BatchId
WHERE m.Quantity > 0;

INSERT INTO dbo.DocumentLine (DocumentId, BatchId, GoodsId, PlaceFromId, Quantity, Price)
SELECT m.DocumentId, m.BatchId, b.GoodsId, m.PlaceId, -m.Quantity, b.Price
FROM dbo.StockMovement m JOIN dbo.Batch b ON b.BatchId = m.BatchId
WHERE m.Quantity < 0;

-- 3.5 Самопроверки: кэш партий против журнала и сводка объёмов.
SELECT N'расхождений кэша Batch.Quantity с журналом' AS check_name,
       COUNT(*) AS bad
FROM dbo.Batch b
    LEFT JOIN (SELECT BatchId, SUM(Quantity) AS s FROM dbo.StockMovement GROUP BY BatchId) m
        ON m.BatchId = b.BatchId
WHERE b.Quantity <> ISNULL(m.s, 0);

SELECT N'партий'     AS what, COUNT(*) AS n FROM dbo.Batch
UNION ALL SELECT N'движений',   COUNT(*) FROM dbo.StockMovement
UNION ALL SELECT N'документов', COUNT(*) FROM dbo.Document
UNION ALL SELECT N'строк',      COUNT(*) FROM dbo.DocumentLine;

EXEC sp_spaceused;

DROP TABLE #seed;
GO

/* --- Очистка ---------------------------------------------------------------
   Тестовые данные изолированы в WarehousePerfTest и не мешают рабочей базе.
   Удалить всё одной командой:
     sqlcmd -S localhost\SQLEXPRESS -E -C -Q "ALTER DATABASE WarehousePerfTest SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE WarehousePerfTest;"
   ============================================================================ */

PRINT N'03_perf_seed.sql: WarehousePerfTest готова. Замеры — 04_perf_measure.sql.';
GO
