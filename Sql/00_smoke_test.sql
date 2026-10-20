/*
  00_smoke_test.sql
  Назначение: убедиться, что MS SQL Express живой, к нему есть доступ,
  и что можно создавать объекты. Никаких данных проекта здесь нет —
  это именно «прогревочный» скрипт.

  Как запускать (два варианта):
    1) SSMS: File -> Open -> File... -> выбрать этот файл -> Execute (F5).
    2) PowerShell:
         sqlcmd -S .\SQLEXPRESS -E -i "D:\AI\Koda Projects\eurotorg-delphi\Sql\00_smoke_test.sql"

  Ключи sqlcmd:
    -S .\SQLEXPRESS  -- имя экземпляра (у тебя может быть другое)
    -E               -- Windows-аутентификация (без логина/пароля)
*/

/* --- 1. Версия, имя машины, имя экземпляра -------------------------------
   Ожидаем: ProductVersion 16.x (2022) или 17.x (2025), Edition содержит "Express".
   InstanceName = SQLEXPRESS значит, что в connection string надо писать ".\SQLEXPRESS". */
SELECT @@VERSION                        AS FullVersion,
       SERVERPROPERTY('MachineName')    AS MachineName,
       SERVERPROPERTY('InstanceName')   AS InstanceName,
       SERVERPROPERTY('ProductVersion') AS ProductVersion,
       SERVERPROPERTY('ProductLevel')   AS ProductLevel,
       SERVERPROPERTY('Edition')        AS Edition,
       SUSER_SNAME()                    AS CurrentLogin;
GO

/* --- 2. По какому протоколу идёт текущее соединение ----------------------
   Нужен, чтобы понять: TCP/IP включён или мы идём через Shared Memory / NP.
   Для локального приложения из FireDAC это обычно не критично, но лучше
   включить TCP/IP сразу — потом меньше сюрпризов с Docker и удалённым доступом. */
SELECT local_net_address AS LocalAddress,
       local_tcp_port    AS LocalTcpPort,
       net_transport     AS Transport
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
GO

/* --- 3. Создаём базу для будущего проекта --------------------------------
   Имя базы по умолчанию по всему проекту: WarehouseDB. */
IF DB_ID(N'WarehouseDB') IS NULL
BEGIN
    CREATE DATABASE WarehouseDB;
    PRINT 'Database WarehouseDB created.';
END
ELSE
    PRINT 'Database WarehouseDB already exists.';
GO

USE WarehouseDB;
GO

/* --- 4. Проверка записи/чтения -------------------------------------------
   Одноразовая таблица-«болванка», её можно удалять без жалости. */
IF OBJECT_ID(N'dbo.SmokeTest') IS NOT NULL
    DROP TABLE dbo.SmokeTest;

CREATE TABLE dbo.SmokeTest
(
    Id        INT IDENTITY(1,1) PRIMARY KEY,
    Msg       NVARCHAR(100) NOT NULL,
    CreatedAt DATETIME2     NOT NULL CONSTRAINT DF_SmokeTest_CreatedAt DEFAULT SYSDATETIME()
);

INSERT INTO dbo.SmokeTest (Msg) VALUES (N'SQL ok'), (N'Next: check FireDAC');

SELECT Id, Msg, CreatedAt
FROM dbo.SmokeTest
ORDER BY Id;
GO

/* --- 5. Проверяем типы, с которыми будем работать ------------------------
   DECIMAL и DATETIME2 должны вести себя ровно как в DDL спецификации. */
SELECT CAST(12345678.123 AS DECIMAL(18,3))        AS QtyTest,   -- количество
       CAST(10.105 AS DECIMAL(18,2))              AS PriceTest, -- цена (округление!)
       CAST('2026-10-10 13:45:00' AS DATETIME2)   AS DateTest;  -- дата/время
GO
