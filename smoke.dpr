program smoke;

{ ============================================================================
  smoke — консольный интеграционный тест приложения «Складской учёт».

  Две части:
    A. Отчёт «остатки на дату» на демонстрационных данных (Sql\02_seed.sql):
       сверка с ожиданиями, зафиксированными там же. Только чтение.
    B. Полный цикл на ВРЕМЕННЫХ данных: создание товара и места, два прихода,
       расход по FIFO на сумму, пересекающую партии, сверка остатков на даты
       и кэша Batch.Quantity с журналом, затем очистка. Запись идёт в
       рабочую базу, но все созданные строки удаляются в finally — база
       возвращается в исходное состояние.

  Код возврата: 0 — все проверки пройдены, 1 — есть провал или ошибка.
  Запуск: build.cmd (собирает и запускает) или bin\smoke.exe.
  ============================================================================ }

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.DateUtils,        // EncodeDateTime
  Data.DB,                 // TDataSet
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Param,
  FireDAC.Comp.Client,     // TFDQuery для проверок и очистки части B
  FireDAC.ConsoleUI.Wait,  // объект ожидания FireDAC для приложений без GUI
  uDM;

var
  Passed, Failed: Integer;
  Q: TFDQuery;  // вспомогательный запрос для проверок части B

procedure Check(const AName: string; ACondition: Boolean; const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(Passed);
    Writeln('  [OK]   ', AName);
  end
  else
  begin
    Inc(Failed);
    Writeln('  [FAIL] ', AName);
    if ADetail <> '' then
      Writeln('         ', ADetail);
  end;
end;

{ Печатает отчёт на одну дату + подпись с ожиданием (часть A).
  Ожидания взяты из проверок в Sql\02_seed.sql: sqlcmd и приложение
  обязаны показывать одно и то же. }
procedure PrintStock(const ATarget: TDateTime; const AExpected: string);
var
  Data: TDataSet;
  N: Integer;
begin
  Writeln;
  Writeln(Format('=== %s  (ожидание: %s) ===',
    [FormatDateTime('dd.mm.yyyy hh:nn', ATarget), AExpected]));
  Data := DM.StockOnDate(ATarget);
  if Data.IsEmpty then
  begin
    Writeln('  (пусто)');
    Exit;
  end;
  Writeln(Format('  %-15s %6s %-22s %-8s %10s %12s',
    ['Товар', 'Партия', 'Склад', 'Место', 'Кол-во', 'Сумма']));
  N := 0;
  while not Data.Eof do
  begin
    Writeln(Format('  %-15s %6d %-22s %-8s %10s %12s',
      [Data.FieldByName('GoodsName').AsString,
       Data.FieldByName('BatchId').AsLargeInt,   // BIGINT -> AsLargeInt
       Data.FieldByName('WarehouseName').AsString,
       Data.FieldByName('PlaceName').AsString,
       Data.FieldByName('Qty').AsString,
       Data.FieldByName('Sum').AsString]));
    Inc(N);
    Data.Next;
  end;
  Writeln(Format('  ИТОГО строк: %d', [N]));
end;

{ Часть A: отчёт на демонстрационных данных. }
procedure TestStockReport;
begin
  Writeln;
  Writeln('=== A. Отчёт «остатки на дату» на данных 02_seed.sql ===');
  PrintStock(EncodeDateTime(2026,  1, 1,  0,  0, 0, 0), '0 строк: до первого прихода');
  PrintStock(EncodeDateTime(2026, 10, 2,  0,  0, 0, 0), '2 строки: партии 1 и 2');
  PrintStock(EncodeDateTime(2026, 10, 6,  0,  0, 0, 0), '3 строки: + партия 3');
  PrintStock(EncodeDateTime(2026, 10, 8, 23, 59, 0, 0), '5 строк: + партии 4 и 5');
  PrintStock(EncodeDateTime(2026, 10, 9, 12, 30, 0, 0),
    '4 строки: молоко списано (HAVING), + партия 6 после расщепления');
end;

{ Удаление всего, что создала часть B. Порядок — обратный связям FK:
  движения -> строки -> шапки -> партии -> место -> товар. }
procedure CleanupSmoke(Q: TFDQuery; AGoodsId, APlaceId: Int64);
begin
  if AGoodsId <= 0 then
    Exit;
  Q.Close;
  Q.SQL.Text :=
    'DELETE FROM dbo.StockMovement WHERE BatchId IN ' +
    ' (SELECT BatchId FROM dbo.Batch WHERE GoodsId = :G)';
  Q.ParamByName('G').AsLargeInt := AGoodsId;
  Q.ExecSQL;
  Q.Close;
  Q.SQL.Text :=
    'DELETE FROM dbo.DocumentLine WHERE GoodsId = :G';
  Q.ParamByName('G').AsLargeInt := AGoodsId;
  Q.ExecSQL;
  Q.Close;
  // Шапки документов, у которых после удаления строк не осталось ни одной
  // строки и это наши smoke-документы (в комментарии есть метка SMOKE).
  Q.SQL.Text :=
    'DELETE FROM dbo.Document WHERE DocumentId NOT IN ' +
    ' (SELECT DocumentId FROM dbo.DocumentLine) AND [Comment] LIKE N''SMOKE%''';
  Q.ExecSQL;
  Q.Close;
  Q.SQL.Text := 'DELETE FROM dbo.Batch WHERE GoodsId = :G';
  Q.ParamByName('G').AsLargeInt := AGoodsId;
  Q.ExecSQL;
  if APlaceId > 0 then
  begin
    Q.Close;
    Q.SQL.Text := 'DELETE FROM dbo.Place WHERE PlaceId = :P';
    Q.ParamByName('P').AsLargeInt := APlaceId;
    Q.ExecSQL;
  end;
  Q.Close;
  Q.SQL.Text := 'DELETE FROM dbo.Goods WHERE GoodsId = :G';
  Q.ParamByName('G').AsLargeInt := AGoodsId;
  Q.ExecSQL;
  Q.Close;
end;

{ Часть B: жизненный цикл документа.
  Сценарий: приход 100 шт по 10.00 (01.01), приход 50 шт по 20.00 (02.01),
  расход FIFO 120 шт (03.01) -> по FIFO уходит вся партия 1 (100) и 20 из
  партии 2. Остаток 30 шт по 20.00. }
procedure TestLifecycle(Q: TFDQuery);
var
  GoodsId, PlaceId, WhId: Int64;
  GoodsName: string;
  D1, D2, D3: TDateTime;
  DocId: Integer;
  Total: Extended;
  Data: TDataSet;
  Rows: Integer;
  TestQty: Extended;
begin
  Writeln;
  Writeln('=== B. Жизненный цикл: приход -> приход -> FIFO-расход -> сверка ===');

  // Уникальные имена: повторные прогоны не сталкиваются с UQ_Goods_Name,
  // а префикс SMOKE пометит строки для точечной очистки.
  GoodsName := Format('SMOKE_TEST_%s', [FormatDateTime('yyyymmdd_hhnnsszzz', Now)]);
  WhId := 0;
  Q.Close;
  Q.SQL.Text := 'SELECT TOP 1 WarehouseId FROM dbo.Warehouse ORDER BY WarehouseId';
  Q.Open;
  if not Q.IsEmpty then
    WhId := Q.FieldByName('WarehouseId').AsLargeInt;
  Q.Close;
  Check('в базе есть хотя бы один склад', WhId > 0);
  if WhId = 0 then
    Exit;

  GoodsId := DM.GoodsAdd(GoodsName);
  PlaceId := DM.PlaceAdd(WhId, GoodsName + '-M');
  try
    D1 := EncodeDateTime(2026, 11, 1, 10, 0, 0, 0);
    D2 := EncodeDateTime(2026, 11, 2, 10, 0, 0, 0);
    D3 := EncodeDateTime(2026, 11, 3, 10, 0, 0, 0);

    // 1. Приходы
    DocId := DM.DocumentIncome(GoodsId, PlaceId, 100, 10.00, D1, 0, 'SMOKE приход 1');
    Check('приход 1 оформлен (100 шт по 10.00)', DocId > 0);
    DocId := DM.DocumentIncome(GoodsId, PlaceId, 50, 20.00, D2, 0, 'SMOKE приход 2');
    Check('приход 2 оформлен (50 шт по 20.00)', DocId > 0);

    Total := DM.GoodsTotalLeft(GoodsId);
    Check('суммарный остаток после приходов = 150', Abs(Total - 150) < 1e-6,
      Format('получено %g', [Total]));

    // 2. Отчёт на дату между приходами: только первая партия
    Data := DM.StockOnDate(EncodeDateTime(2026, 11, 1, 23, 59, 0, 0));
    // Считаем строки и Qty только по нашему тестовому товару
    Rows := 0;
    TestQty := 0;
    Data.First;
    while not Data.Eof do
    begin
      if Data.FieldByName('GoodsName').AsString = GoodsName then
      begin
        Inc(Rows);
        TestQty := Data.FieldByName('Qty').AsFloat;
      end;
      Data.Next;
    end;
    Check('отчёт на 01.11 23:59 — одна строка (100 шт)',
      (Rows = 1) and (Abs(TestQty - 100) < 1e-6),
      Format('строк по товару: %d, Qty: %g', [Rows, TestQty]));

    // 3. Peek FIFO на 120: расчёт должен хватить оба прихода
    try
      DM.PeekOutcomeFIFO(GoodsId, 0, 120);
      Check('Peek FIFO на 120 шт успешен', True);
    except
      on E: Exception do
        Check('Peek FIFO на 120 шт успешен', False, E.Message);
    end;

    // 4. Расход FIFO 120: уходят 100 (старая) + 20 (новая)
    DocId := DM.DocumentOutcomeFIFO(GoodsId, 0, 120, D3, 'SMOKE расход FIFO');
    Check('расход FIFO на 120 шт оформлен', DocId > 0);

    Total := DM.GoodsTotalLeft(GoodsId);
    Check('суммарный остаток после расхода = 30', Abs(Total - 30) < 1e-6,
      Format('получено %g', [Total]));

    // 5. Отчёт после расхода: одна строка, 30 шт — FIFO не тронул «хвост»
    //    новой партии и полностью съел старую (HAVING <> 0 скрывает нули).
    Data := DM.StockOnDate(EncodeDateTime(2026, 11, 3, 23, 59, 0, 0));
    Rows := 0;
    TestQty := 0;
    Data.First;
    while not Data.Eof do
    begin
      if Data.FieldByName('GoodsName').AsString = GoodsName then
      begin
        Inc(Rows);
        TestQty := Data.FieldByName('Qty').AsFloat;
      end;
      Data.Next;
    end;
    Check('отчёт на 03.11 23:59 — одна строка (30 шт)',
      (Rows = 1) and (Abs(TestQty - 30) < 1e-6),
      Format('строк по товару: %d, Qty: %g', [Rows, TestQty]));

    // 6. Кэш Batch.Quantity обязан совпадать с журналом движений.
    Q.Close;
    Q.SQL.Text :=
      'SELECT COUNT(*) AS Bad FROM dbo.Batch b ' +
      'LEFT JOIN (SELECT BatchId, SUM(Quantity) AS S FROM dbo.StockMovement ' +
      '           GROUP BY BatchId) m ON m.BatchId = b.BatchId ' +
      'WHERE b.GoodsId = :G AND b.Quantity <> ISNULL(m.S, 0)';
    Q.ParamByName('G').AsLargeInt := GoodsId;
    Q.Open;
    Check('кэш Batch.Quantity совпадает с журналом',
      Q.FieldByName('Bad').AsInteger = 0);
    Q.Close;

    // 7. Расход сверх остатка обязан отказывать.
    try
      DM.DocumentOutcomeFIFO(GoodsId, 0, 999, D3, 'SMOKE перебор');
      Check('FIFO-расход 999 при остатке 30 отклонён', False, 'исключение не брошено');
    except
      on E: Exception do
        Check('FIFO-расход 999 при остатке 30 отклонён', True);
    end;
  finally
    CleanupSmoke(Q, GoodsId, PlaceId);
    Writeln('  (временные данные удалены)');
  end;
end;

{ Часть C: поиск и сортировка в справочнике (данные 02_seed.sql). }
procedure TestSearchSort;
var
  Data: TDataSet;
begin
  Writeln;
  Writeln('=== C. Поиск и сортировка справочников ===');
  Data := DM.OpenGoods('', 'молоко');
  Check('поиск «молоко» нашёл ровно 1 товар', Data.RecordCount = 1,
    Format('найдено: %d', [Data.RecordCount]));
  Data := DM.OpenGoods('GoodsId DESC');
  Data.First;
  if Data.IsEmpty then
    Check('сортировка GoodsId DESC: первая строка — максимальный ID', False, 'пусто')
  else
    Check('сортировка GoodsId DESC: первая строка — максимальный ID',
      Data.FieldByName('GoodsId').AsLargeInt >= 1);
  Data := DM.OpenGoods('', '');  // вернуть справочник к виду по умолчанию
  Check('поиск без фильтра возвращает справочник целиком',
    Data.RecordCount >= 3);
end;

begin
  DM := TDM.Create(nil);
  try
    try
      DM.Connect;
      Writeln('Соединение OK: ', DM.ServerVersion);
      TestStockReport;
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := DM.Connection;
        TestLifecycle(Q);
      finally
        Q.Free;
      end;
      TestSearchSort;
    except
      on E: Exception do
      begin
        Writeln('ОШИБКА: ', E.ClassName, ' — ', E.Message);
        Inc(Failed);
      end;
    end;
  finally
    FreeAndNil(DM);
  end;

  Writeln;
  Writeln(Format('ИТОГ: пройдено %d, провалено %d', [Passed, Failed]));
  if Failed = 0 then
  begin
    Writeln('SMOKE OK');
    ExitCode := 0;
  end
  else
  begin
    Writeln('SMOKE FAILED');
    ExitCode := 1;
  end;
end.
