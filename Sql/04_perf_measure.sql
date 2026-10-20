/* ============================================================================
   04_perf_measure.sql — замеры производительности ключевых запросов

   Запуск (БД WarehousePerfTest должна быть создана 03_perf_seed.sql):
     sqlcmd -S localhost\SQLEXPRESS -E -C -i Sql\04_perf_measure.sql

   Замеряет:
     1. usp_StockOnDate — отчёт «остатки на дату»
     2. FIFO-подбор партий — как DocumentOutcomeFIFO
     3. Поиск LIKE '%...%' — как поиск в справочниках

   Выводит время выполнения и статистику. Данные не меняет.
   ============================================================================ */

USE WarehousePerfTest;
GO

SET NOCOUNT ON;
SET STATISTICS TIME, IO ON;

/* --- 1. usp_StockOnDate --------------------------------------------------
   Результат складываем в таблицу-переменную: без этого sqlcmd вывел бы
   десятки тысяч строк и время вывода смешалось бы с временем запроса. */
PRINT '=== 1. usp_StockOnDate: остатки на 2026-10-19 12:00 ===';
DECLARE @Target DATETIME2 = '2026-10-19 12:00:00';
DECLARE @res TABLE (
    GoodsName NVARCHAR(100), BatchId BIGINT, WarehouseName NVARCHAR(100),
    PlaceName NVARCHAR(100), IncomeDate DATETIME2, ExpiryDate DATETIME2,
    Price DECIMAL(18,2), Qty DECIMAL(18,3), Sum DECIMAL(38,5));
INSERT INTO @res EXEC dbo.usp_StockOnDate @Target;
SELECT COUNT(*) AS stok_rows FROM @res;
GO

/* --- 2. FIFO-подбор партий (аналог DocumentOutcomeFIFO) ------------------- */
PRINT '=== 2. FIFO-подбор 1000 шт (товар 1) ===';
DECLARE @FifoGoodsId BIGINT = 1, @FifoQty DECIMAL(18,3) = 1000;

SELECT b.BatchId, b.GoodsId, b.PlaceId, b.Price,
       ISNULL(SUM(m.Quantity), 0) AS QtyLeft
FROM dbo.Batch b
    JOIN dbo.Place p ON p.PlaceId = b.PlaceId
    LEFT JOIN dbo.StockMovement m ON m.BatchId = b.BatchId
WHERE b.GoodsId = @FifoGoodsId
GROUP BY b.BatchId, b.GoodsId, b.PlaceId, b.Price, b.IncomeDate
HAVING ISNULL(SUM(m.Quantity), 0) > 0
ORDER BY b.IncomeDate, b.BatchId;
GO

/* --- 3. Поиск LIKE (как в OpenGoods) ------------------------------------- */
PRINT '=== 3. Поиск LIKE ''Товар_00001'' в 5000 товарах ===';
SELECT GoodsId, GoodsName FROM dbo.Goods
WHERE GoodsName LIKE N'Товар_00001%'
ORDER BY GoodsName;
GO

PRINT '=== 4. Поиск LIKE ''Товар_%001'' (бесточечный, 10 совпадений) ===';
SELECT GoodsId, GoodsName FROM dbo.Goods
WHERE GoodsName LIKE N'Товар_%001%'
ORDER BY GoodsName;
GO

SET STATISTICS TIME, IO OFF;
PRINT '=== Замеры завершены ===';
GO
