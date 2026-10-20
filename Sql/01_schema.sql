/* ============================================================================
   01_schema.sql  —  схема БД «Складской учёт»

   Источник: SPECIFICATION.md II.2.2 (DDL) + расширени, разрешённые разделом I.2.

   Запуск:
     sqlcmd -S localhost\SQLEXPRESS -E -C -i Sql\01_schema.sql

   Скрипт идемпотентен: сначала роняет объекты в обратном порядке зависимостей,
   потом создаёт заново. Данные при этом теряются — после него обязательно
   выполнить 02_seed.sql.
   ============================================================================ */

USE master;
GO

IF DB_ID(N'WarehouseDB') IS NULL
    CREATE DATABASE WarehouseDB;
GO

USE WarehouseDB;
GO

/* --- 0. Удаление существующих объектов -----------------------------------
   Порядок обратный связям: процедура -> регистр -> строки -> шапка -> партии
   -> справочники. Таблицу SmokeTest не трогаем: это артефакт смоук-теста. */

IF OBJECT_ID(N'dbo.usp_StockOnDate') IS NOT NULL
    DROP PROCEDURE dbo.usp_StockOnDate;
GO

IF OBJECT_ID(N'dbo.StockMovement') IS NOT NULL DROP TABLE dbo.StockMovement;
IF OBJECT_ID(N'dbo.DocumentLine')  IS NOT NULL DROP TABLE dbo.DocumentLine;
IF OBJECT_ID(N'dbo.Document')      IS NOT NULL DROP TABLE dbo.Document;
IF OBJECT_ID(N'dbo.Batch')         IS NOT NULL DROP TABLE dbo.Batch;
IF OBJECT_ID(N'dbo.Place')         IS NOT NULL DROP TABLE dbo.Place;
IF OBJECT_ID(N'dbo.Warehouse')     IS NOT NULL DROP TABLE dbo.Warehouse;
IF OBJECT_ID(N'dbo.Goods')         IS NOT NULL DROP TABLE dbo.Goods;
GO

/* ============================================================================
   1. СПРАВОЧНИКИ

   NVARCHAR, а не VARCHAR: в VARCHAR кириллица превращается в "??????".
   DECIMAL, а не FLOAT: для денег и количеств (SPECIFICATION.md II.3, п.5).
   ============================================================================ */

CREATE TABLE dbo.Goods
(
    GoodsId   BIGINT IDENTITY(1,1) NOT NULL,
    GoodsName NVARCHAR(100)        NOT NULL,

    CONSTRAINT PK_Goods PRIMARY KEY (GoodsId),
    -- Без уникальности через месяц появляются «Молоко» и «Молоко » с пробелом,
    -- и остатки по одному товару разъезжаются по двум строкам.
    CONSTRAINT UQ_Goods_Name UNIQUE (GoodsName)
);
GO

CREATE TABLE dbo.Warehouse
(
    WarehouseId   BIGINT IDENTITY(1,1) NOT NULL,
    WarehouseName NVARCHAR(100)        NOT NULL,

    CONSTRAINT PK_Warehouse PRIMARY KEY (WarehouseId),
    CONSTRAINT UQ_Warehouse_Name UNIQUE (WarehouseName)
);
GO

CREATE TABLE dbo.Place
(
    PlaceId     BIGINT IDENTITY(1,1) NOT NULL,
    WarehouseId BIGINT               NOT NULL,
    -- Название места: расширение, прямо разрешённое разделом I.2.
    -- Без него оператор видит «PlaceId 17» вместо «А-1-3».
    PlaceName   NVARCHAR(100)        NOT NULL,

    CONSTRAINT PK_Place PRIMARY KEY (PlaceId),
    CONSTRAINT FK_Place_Warehouse FOREIGN KEY (WarehouseId)
        REFERENCES dbo.Warehouse (WarehouseId),
    -- Место уникально ВНУТРИ склада: «А-1-3» на разных складах — разные места.
    CONSTRAINT UQ_Place_Name UNIQUE (WarehouseId, PlaceName)
);
GO

/* ============================================================================
   2. ПАРТИИ

   Batch = партия товара в конкретном месте.
   Quantity — КЭШ текущего остатка. Точка правды для отчётов на дату —
   StockMovement (SPECIFICATION.md II.2.1). Кэш нужен, чтобы FIFO и проверка
   «не уйти в минус» не пересчитывали сумму движений на каждой строке.
   Расхождение кэша с журналом ловит проверка №2 в 02_seed.sql.

   IncomeDate — ключ сортировки FIFO, поэтому NOT NULL и входит в индекс.
   ============================================================================ */

CREATE TABLE dbo.Batch
(
    BatchId    BIGINT IDENTITY(1,1) NOT NULL,
    GoodsId    BIGINT               NOT NULL,
    PlaceId    BIGINT               NOT NULL,
    Quantity   DECIMAL(18,3)        NOT NULL,
    Price      DECIMAL(18,2)        NOT NULL,   -- цена ПАРТИИ, не товара
    IncomeDate DATETIME2            NOT NULL,   -- FIFO-ключ
    ExpiryDate DATETIME2            NULL,       -- NULL = срок не задан

    CONSTRAINT PK_Batch PRIMARY KEY (BatchId),
    CONSTRAINT FK_Batch_Goods FOREIGN KEY (GoodsId) REFERENCES dbo.Goods (GoodsId),
    CONSTRAINT FK_Batch_Place FOREIGN KEY (PlaceId) REFERENCES dbo.Place (PlaceId),
    -- Минус в остатке = баг в логике расхода. Ловим на границе БД.
    CONSTRAINT CK_Batch_Quantity CHECK (Quantity >= 0)
);
GO

/* ============================================================================
   3. ДОКУМЕНТЫ

   DocType: 1 = Приход, 2 = Перемещение, 3 = Расход (SPECIFICATION.md II.2.2).
   TINYINT + CHECK вместо отдельного справочника: значений три, они не меняются.
   ============================================================================ */

CREATE TABLE dbo.Document
(
    DocumentId BIGINT IDENTITY(1,1) NOT NULL,
    DocType    TINYINT              NOT NULL,
    DocDate    DATETIME2            NOT NULL,
    [Comment]  NVARCHAR(255)        NULL,

    CONSTRAINT PK_Document PRIMARY KEY (DocumentId),
    CONSTRAINT CK_Document_DocType CHECK (DocType IN (1, 2, 3))
);
GO

CREATE TABLE dbo.DocumentLine
(
    LineId      BIGINT IDENTITY(1,1) NOT NULL,
    DocumentId  BIGINT               NOT NULL,
    BatchId     BIGINT               NULL,   -- NULL на приходе: партии ещё нет
    GoodsId     BIGINT               NOT NULL,
    PlaceFromId BIGINT               NULL,   -- расход / перемещение
    PlaceToId   BIGINT               NULL,   -- приход / перемещение
    Quantity    DECIMAL(18,3)        NOT NULL,
    Price       DECIMAL(18,2)        NULL,   -- на расходе цена берётся из партии

    CONSTRAINT PK_DocumentLine PRIMARY KEY (LineId),
    -- В DDL из II.2.2 был только FK на Document. Остальные — моё дополнение:
    -- без них в строку впишется несуществующий товар, и это всплывёт только
    -- при чтении отчёта.
    CONSTRAINT FK_Line_Document FOREIGN KEY (DocumentId)  REFERENCES dbo.Document (DocumentId),
    CONSTRAINT FK_Line_Batch    FOREIGN KEY (BatchId)     REFERENCES dbo.Batch    (BatchId),
    CONSTRAINT FK_Line_Goods    FOREIGN KEY (GoodsId)     REFERENCES dbo.Goods    (GoodsId),
    CONSTRAINT FK_Line_From     FOREIGN KEY (PlaceFromId) REFERENCES dbo.Place    (PlaceId),
    CONSTRAINT FK_Line_To       FOREIGN KEY (PlaceToId)   REFERENCES dbo.Place    (PlaceId),
    -- Пустая строка в документе — мусор, а не данные.
    CONSTRAINT CK_DocumentLine_Quantity CHECK (Quantity > 0)
);
GO

/* ============================================================================
   4. РЕГИСТР ДВИЖЕНИЙ — ЕДИНАЯ ТОЧКА ПРАВДЫ

   Quantity со знаком: + приход, - расход. Перемещение = две строки (- и +).
   MovementDate берём из Document.DocDate, а не из SYSDATETIME(): отчёт
   «на дату» обязан показывать прошлое так, каким оно было.
   ============================================================================ */

CREATE TABLE dbo.StockMovement
(
    MovementId   BIGINT IDENTITY(1,1) NOT NULL,
    BatchId      BIGINT               NOT NULL,
    PlaceId      BIGINT               NOT NULL,
    Quantity     DECIMAL(18,3)        NOT NULL,
    MovementDate DATETIME2            NOT NULL,
    DocumentId   BIGINT               NULL,

    CONSTRAINT PK_StockMovement PRIMARY KEY (MovementId),
    CONSTRAINT FK_Mov_Batch    FOREIGN KEY (BatchId)    REFERENCES dbo.Batch    (BatchId),
    CONSTRAINT FK_Mov_Place    FOREIGN KEY (PlaceId)    REFERENCES dbo.Place    (PlaceId),
    CONSTRAINT FK_Mov_Document FOREIGN KEY (DocumentId) REFERENCES dbo.Document (DocumentId),
    -- Нулевого движения не бывает.
    CONSTRAINT CK_StockMovement_Quantity CHECK (Quantity <> 0)
);
GO

/* ============================================================================
   5. ИНДЕКСЫ
   ============================================================================ */

-- FIFO и проверка остатка: «сумма движений партии в месте до даты».
CREATE INDEX IX_Mov_BatchPlace_Date
    ON dbo.StockMovement (BatchId, PlaceId, MovementDate);

-- FIFO: партии товара по дате прихода.
CREATE INDEX IX_Batch_Goods_IncomeDate
    ON dbo.Batch (GoodsId, IncomeDate);

-- Выпадающий список мест на складе.
CREATE INDEX IX_Place_Warehouse
    ON dbo.Place (WarehouseId);

-- Под отчёт II.2.4: он фильтрует ПО ДАТЕ, а три индекса выше MovementDate
-- первым не имеют. INCLUDE превращает скан в покрытое чтение.
CREATE INDEX IX_Mov_Date_Covering
    ON dbo.StockMovement (MovementDate)
    INCLUDE (BatchId, PlaceId, Quantity);
GO

/* ============================================================================
   6. ОТЧЁТ «ОСТАТКИ НА ДАТУ И ВРЕМЯ»

   Запрос из II.2.4, завёрнутый в процедуру: контракт отчёта живёт рядом
   со схемой и правится без перекомпиляции приложения.

   Отличие от II.2.4: добавлены WarehouseName, PlaceName и сумма. Учёт по
   заданию количественно-СУММОВОЙ (раздел I.1), в исходном запросе денег не было.
   ============================================================================ */

CREATE OR ALTER PROCEDURE dbo.usp_StockOnDate
    @Target DATETIME2   -- на какой момент считаем, включая эту секунду
AS
BEGIN
    SET NOCOUNT ON;     -- без него клиент получает лишние сообщения «rows affected»

    SELECT g.GoodsName,
           b.BatchId,
           w.WarehouseName,
           p.PlaceName,
           b.IncomeDate,
           b.ExpiryDate,
           b.Price,
           SUM(m.Quantity)           AS Qty,   -- DECIMAL(18,3)
           SUM(m.Quantity) * b.Price AS Sum    -- стоимость партии на этот момент
    FROM dbo.StockMovement AS m
        INNER JOIN dbo.Batch     AS b ON b.BatchId    = m.BatchId
        INNER JOIN dbo.Goods     AS g ON g.GoodsId    = b.GoodsId
        INNER JOIN dbo.Place     AS p ON p.PlaceId    = m.PlaceId
        INNER JOIN dbo.Warehouse AS w ON w.WarehouseId = p.WarehouseId
    WHERE m.MovementDate <= @Target            -- <= : «на 13:45:00» включает 13:45:00
    GROUP BY g.GoodsName, b.BatchId, w.WarehouseName, p.PlaceName,
             b.IncomeDate, b.ExpiryDate, b.Price
    HAVING SUM(m.Quantity) <> 0                -- полностью списанные партии не показываем
    ORDER BY g.GoodsName, b.IncomeDate;        -- FIFO-порядок прямо в выдаче
END
GO

PRINT N'01_schema.sql: схема создана.';
GO
