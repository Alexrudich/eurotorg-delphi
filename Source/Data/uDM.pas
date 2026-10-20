unit uDM;

{ ============================================================================
  uDM — единственный модуль доступа к данным.

  ПОЧЕМУ НАСЛЕДУЕТСЯ ОТ TComponent, А НЕ ОТ TDataModule:
    TDataModule при создании ищет в exe ресурс .dfm/.fmx и бросает
    EResNotFound, если ресурса нет. Нам ресурс не нужен: все компоненты
    создаются кодом в конструкторе. TComponent даёт ровно то же самое
    (владение компонентами, автоосвобождение), но без зависимости от DFM.
    Когда добавим FMX-формы с .fmx — базовый класс поменяем без изменения
    публичного API, формы этого не заметят.

  Почему один модуль на все запросы, а не подключение в каждой форме:
    соединение живёт дольше формы. Аналог в .NET — единый DbContext/репозиторий,
    а не new SqlConnection в каждом обработчике клика.
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes, System.Variants, System.StrUtils, Data.DB,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Error,
  FireDAC.Stan.Def, FireDAC.Stan.Async,
  FireDAC.Stan.Param,
  FireDAC.Phys, FireDAC.Phys.ODBCBase, FireDAC.Phys.ODBC,
  // FireDAC.Phys.MSSQL нужен, хотя класса TFDPhysMSSQLDriver в коде нет.
  // В initialization-секции этого юнита вызывается FDRegisterDriverClass,
  // который заносит драйвер с DriverID='MSSQL' в реестр драйверов FireDAC.
  // Без юнита запись в реестре отсутствует, и DriverID='MSSQL' даёт ошибку
  // -340 «Driver ID is not defined». FireDAC.Phys.ODBC регистрирует только
  // универсальный 'ODBC' — он про SQL Server ничего не знает.
  FireDAC.Phys.MSSQL,
  FireDAC.Comp.Client,
  // FireDAC.DApt обязателен, хотя в тексте кода ни одного его имени нет.
  // FireDAC разбит на слои: Phys.* умеет говорить с драйвером, Comp.Client
  // даёт класс TFDQuery, а DApt («Data Access Provider») при подключении
  // юнита регистрирует в объектной фабрике класс курсора, который превращает
  // ответ драйвера в обычный TDataSet. Без него TFDQuery.Open падает с
  // «Object factory for class {3E9B315B-...} is missing» — по сути это
  // аналог отсутствующего провайдера ADO.NET.
  FireDAC.DApt;

type
  // Одна строка «партия + сколько из неё списываем». Используется расходом:
  // FIFO набирает таких строк несколько (частичное списание по партиям),
  // ручное списание передаёт ровно одну.
  TBatchTake = record
    BatchId: Int64;
    GoodsId: Int64;
    PlaceId: Int64;
    Qty: Extended;
    Price: Extended;
  end;

  // Снимок состояния курсоров справочников: какие из них были открыты до
  // операции. Расход и приход закрывают их на время транзакции и обязаны
  // вернуть в исходное состояние — иначе гриды вкладок опустеют.
  // Batches — курсор списка партий вкладки «Расход»: он такой же «постоянно
  // открытый», как и справочники, поэтому участвует в сохранении наравне.
  TDictCursorState = record
    Goods: Boolean;
    Warehouses: Boolean;
    Places: Boolean;
    Batches: Boolean;
    Documents: Boolean;
    DocLines: Boolean;
  end;

  TDM = class(TComponent)
  private
    FCon: TFDConnection;          // соединение с WarehouseDB
    FQry: TFDQuery;               // универсальный запрос (CRUD, диагностика)
    FQryStock: TFDQuery;          // запрос отчёта «остатки на дату»
    FQryGoods: TFDQuery;          // грид справочника «Товары»
    FQryWarehouses: TFDQuery;     // грид справочника «Склады»
    FQryPlaces: TFDQuery;         // грид справочника «Места»
    FQryBatches: TFDQuery;        // партии с остатком (для вкладки «Расход»)
    FQryDocuments: TFDQuery;      // реестр документов (вкладка «Документы»)
    FQryDocLines: TFDQuery;       // строки выбранного документа
    FTransaction: TFDTransaction; // транзакция на один документ

    // Общий «движок» списания: создаёт Document (DocType=3), по строке
    // DocumentLine и StockMovement(−) на каждую партию, уменьшает Batch.Quantity.
    // Курсоры справочников НЕ трогает — это обязанность вызывающего: FIFO
    // читает партии тем же курсором, что и справочники, поэтому управление
    // курсорами должно быть выше по стеку.
    function DoOutcome(const ATakes: array of TBatchTake; ADocDate: TDateTime;
      const AComment: string): Integer;
    // Закрывает курсоры справочников, вернув в AState, какие были открыты.
    procedure SaveAndCloseDictCursors(out AState: TDictCursorState);
    // Парная к SaveAndCloseDictCursors: открывает обратно только то,
    // что было открыто.
    procedure RestoreDictCursors(const AState: TDictCursorState);
    function GetServerName: string;
    function GetDatabaseName: string;
    // Белый список для ORDER BY: принимает только «Колонка» или
    // «Колонка ASC|DESC» из AAllowed, иначе возвращает ADefault.
    // ORDER BY параметром не параметризуется (это не значение, а часть
    // плана запроса), поэтому единственный безопасный путь — сверка
    // со списком разрешённых имён.
    function SafeSort(const ASortBy: string;
      const AAllowed: array of string; const ADefault: string): string;
  protected
    procedure BuildComponents;       // создаёт и настраивает компоненты
    procedure ApplyConnectionParams; // задаёт строку подключения
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // --- соединение ---
    procedure Connect;               // идемпотентно: повторный вызов безвреден
    procedure Disconnect;
    function IsConnected: Boolean;

    // --- диагностика ---
    function ServerVersion: string;  // @@VERSION — проверка, что коннект живой

    // --- отчёт «остатки на дату и время» (SPECIFICATION.md II.2.4) ---
    // Открывает FQryStock процедурой dbo.usp_StockOnDate и возвращает её как
    // TDataSet для вывода в TGrid. Вызывающий НЕ освобождает датасет.
    function StockOnDate(const ATarget: TDateTime): TDataSet;

    // --- справочники: каждый со своим TFDQuery, чтобы гриды не мешали друг другу ---
    // ASortBy — имя колонки ORDER BY ('' = порядок по умолчанию);
    // AFilter — подстрока поиска, экранируется и уходит в LIKE '%...%'.
    // Вызов без параметров идентичен прежнему OpenGoods и т.д.
    function OpenGoods(const ASortBy: string = '';
      const AFilter: string = ''): TDataSet;
    function OpenWarehouses(const ASortBy: string = '';
      const AFilter: string = ''): TDataSet;
    function OpenPlaces(const ASortBy: string = '';
      const AFilter: string = ''): TDataSet;

    // --- CRUD: Товары ---
    function GoodsAdd(const AGoodsName: string): Integer;
    procedure GoodsUpdate(AGoodsId: Integer; const AGoodsName: string);
    procedure GoodsDelete(AGoodsId: Integer);

    // --- CRUD: Склады ---
    function WarehouseAdd(const AWarehouseName: string): Integer;
    procedure WarehouseUpdate(AWarehouseId: Integer; const AWarehouseName: string);
    procedure WarehouseDelete(AWarehouseId: Integer);

    // --- CRUD: Места ---
    function PlaceAdd(AWarehouseId: Integer; const APlaceName: string): Integer;
    procedure PlaceUpdate(APlaceId: Integer; AWarehouseId: Integer; const APlaceName: string);
    procedure PlaceDelete(APlaceId: Integer);

    // --- приход (SPECIFICATION.md II.2.3) ---
    // В одной транзакции создаёт Batch, Document (DocType=1), DocumentLine
    // и StockMovement (+). Возвращает DocumentId.
    // AExpiryDate <= 0 означает «срок не задан» -> в БД уходит NULL.
    // ADocDate используется и как Batch.IncomeDate (ключ FIFO), и как
    // StockMovement.MovementDate: отчёт «на дату» обязан показывать прошлое
    // таким, каким оно было, поэтомуMovementDate берётся из документа,
    // а не из SYSDATETIME().
    function DocumentIncome(AGoodsId, APlaceId: Int64; AQnty, APrice: Extended;
      ADocDate, AExpiryDate: TDateTime; const AComment: string): Integer;

    // --- расход (SPECIFICATION.md II.2.3) ---
    // Список партий товара, отсортированный по IncomeDate ASC (FIFO-порядок).
    // Остаток считается суммой StockMovement, а не по Batch.Quantity:
    // движение точнее отражает историю. AShowZero = True добавляет к списку
    // и полностью израсходованные партии (остаток 0) — интерфейсу они нужны,
    // чтобы «исчезновение» строки не выглядело потерей данных.
    // Колонка WarehouseId нужна форме для фильтра «склад» без нового запроса.
    // Возвращает курсор FQryBatches.
    function OpenBatchesForGoods(AGoodsId: Int64;
      AShowZero: Boolean = False): TDataSet;

    // Расход вручную: списание одной выбранной партии в количестве AQnty.
    // AQnty не должен превышать остаток партии — проверка на стороне БД через
    // CK_Batch_Quantity (Quantity >= 0), но лучше поймать раньше.
    function DocumentOutcomeManual(ABatchId: Int64; AQnty: Extended;
      ADocDate: TDateTime; const AComment: string): Integer;

    // Расход по FIFO: набирает партии AGoodsId на складе AWarehouseId
    // (0 = без фильтра склада) в порядке IncomeDate ASC, пока не наберёт
    // AQnty. Бросает исключение, если суммарного остатка не хватает.
    function DocumentOutcomeFIFO(AGoodsId, AWarehouseId: Int64; AQnty: Extended;
      ADocDate: TDateTime; const AComment: string): Integer;

    // --- реестр документов ---
    // Возвращает курсор FQryDocuments: DocumentId, DocType (1/2/3),
    // DocTypeName ('Приход'/'Перемещение'/'Расход'), DocDate, [Comment],
    // LineCount (кол-во строк), TotalQty (сумма Qty по строкам).
    function OpenDocuments(const AFrom, ATo: TDateTime;
      ADocType: Integer; const AFilter: string = ''): TDataSet;

    // Строки выбранного документа: что именно пришло/ушло/переместилось.
    // Возвращает курсор FQryDocLines с колонками BatchId, GoodsName,
    // PlaceFromName, PlaceToName, Quantity, Price.
    function OpenDocumentLines(ADocumentId: Int64): TDataSet;

    // --- Peek (расчёт без записи) ---
    // При успехе возвращают текст «что будет списано» для диалога
    // подтверждения; при неудаче бросают Exception с причиной (не хватает
    // остатка, партия не найдена). Форма различает исход через try/except.
    function PeekOutcomeFIFO(AGoodsId, AWarehouseId: Int64; AQnty: Extended): string;
    function PeekOutcomeManual(ABatchId: Int64; AQnty: Extended): string;

    // Перемещение партии ABatchId на новое место ANewPlaceId.
    // Создаёт новую партию на новом месте с той же ценой и количеством AQnty,
    // уменьшает старую партию.
    function DocumentTransfer(ABatchId, ANewPlaceId: Int64;
      AQnty: Extended; ADocDate: TDateTime; const AComment: string): Integer;

    // Суммарный остаток товара по всем складам — строка «Остаток: N шт».
    function GoodsTotalLeft(AGoodsId: Int64): Extended;

    // --- свойства для чтения открытых курсоров справочников формой ---
    // Эти же датасеты используются гридами CRUD; форма читает их для
    // заполнения комбобоксов прихода без новых запросов (без MARS нельзя
    // держать два активных курсора на одном соединении).
    // Тип свойства — TFDQuery, а не TDataSet: в Object Pascal тип свойства
    // обязан совпадать с типом поля-геттера (неявное восходящее приведение
    // разрешено только в операторах присваивания, но не в объявлении).
    // Вызывающий код спокойно использует их как TDataSet.
    property GoodsDataSet: TFDQuery read FQryGoods;
    property WarehousesDataSet: TFDQuery read FQryWarehouses;
    property PlacesDataSet: TFDQuery read FQryPlaces;
    property BatchesDataSet: TFDQuery read FQryBatches;
    property DocumentsDataSet: TFDQuery read FQryDocuments;
    property DocLinesDataSet: TFDQuery read FQryDocLines;

    property Connection: TFDConnection read FCon;
    property ServerName: string read GetServerName;
    property DatabaseName: string read GetDatabaseName;
  end;

var
  DM: TDM;

implementation

constructor TDM.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BuildComponents;
end;

procedure TDM.BuildComponents;
begin
  FCon := TFDConnection.Create(Self);
  FCon.Name := 'conWarehouse';
  FCon.LoginPrompt := False;   // без этого FireDAC покажет своё окно логина

  FQry := TFDQuery.Create(Self);
  FQry.Name := 'qryMain';
  FQry.Connection := FCon;

  FQryStock := TFDQuery.Create(Self);
  FQryStock.Name := 'qryStock';
  FQryStock.Connection := FCon;

  // Отдельный запрос на каждый справочник. Если бы все три грида ссылались
  // на один TFDQuery, переключение вкладки «Товары -> Склады» перезаписывало
  // бы SQL-текст, и первый грид остался бы с колонками от чужого запроса.
  FQryGoods := TFDQuery.Create(Self);
  FQryGoods.Name := 'qryGoods';
  FQryGoods.Connection := FCon;

  FQryWarehouses := TFDQuery.Create(Self);
  FQryWarehouses.Name := 'qryWarehouses';
  FQryWarehouses.Connection := FCon;

  FQryPlaces := TFDQuery.Create(Self);
  FQryPlaces.Name := 'qryPlaces';
  FQryPlaces.Connection := FCon;

  FQryBatches := TFDQuery.Create(Self);
  FQryBatches.Name := 'qryBatches';
  FQryBatches.Connection := FCon;

  FQryDocuments := TFDQuery.Create(Self);
  FQryDocuments.Name := 'qryDocuments';
  FQryDocuments.Connection := FCon;

  FQryDocLines := TFDQuery.Create(Self);
  FQryDocLines.Name := 'qryDocLines';
  FQryDocLines.Connection := FCon;

  FTransaction := TFDTransaction.Create(Self);
  FTransaction.Name := 'trnDocument';
  FTransaction.Connection := FCon;
end;

function TDM.GetServerName: string;
begin
  // Именованный экземпляр Express. Обратный слэш в Pascal-строке литерален.
  Result := 'localhost\SQLEXPRESS';
end;

function TDM.GetDatabaseName: string;
begin
  Result := 'WarehouseDB';
end;

procedure TDM.ApplyConnectionParams;
begin
  // FireDAC через ODBC-драйвер. Почему не родной MSSQL-драйвер (OLE DB)?
  // На этой машине ODBC Driver 18 для SQL Server уже настроен, а OLE DB
  // требует отдельного провайдера. ODBC работает из коробки.
  // Порядок важен: DriverName присваиваем ПОСЛЕ Params.Clear.
  //   FCon.DriverName := 'MSSQL' изнутри пишет значение в Params (ключ
  //   'DriverID'), поэтому любой Clear ПОСЛЕ присваивания стёр бы его —
  //   это и была ошибка -340 «Driver ID is not defined».
  FCon.Params.Clear;
  FCon.DriverName := 'MSSQL';
  // Ключ называется ODBCDriver (константа S_FD_ConnParam_ODBC_ODBCDriver в
  // FireDAC.Stan.Consts.pas), а не DriverName: 'DriverName' — это имя
  // свойства TFDConnection, и как параметр строки подключения оно игнорируется.
  FCon.Params.Add('ODBCDriver=ODBC Driver 18 for SQL Server');
  FCon.Params.Add('Server=' + ServerName);
  FCon.Params.Add('Database=' + DatabaseName);
  // Windows-аутентификация. Ключ FireDAC называется OSAuthent, а НЕ
  // Trusted_Connection: в FireDAC.Phys.MSSQL.pas (строка 494) задан маппинг
  // 'OSAuthent' -> 'Trusted_Connection', то есть FireDAC сам подставит
  // нужный ODBC-ключ. Без OSAuthent запрос уходит без логина, и сервер
  // отвечает "Login failed for user ''".
  FCon.Params.Add('OSAuthent=Yes');
  // Драйвер 18 по умолчанию шифрует соединение и требует доверенный сертификат.
  // У локального SQLEXPRESS сертификат самоподписанный, поэтому его нужно
  // явно разрешить. ВАЖНО: писать 'TrustServerCertificate=Yes' обычным
  // параметром бесполезно — драйвер MSSQL в FireDAC знает ограниченное число
  // ключей (Server, Database, Encrypt, MARS...) и прочие молча выбрасывает,
  // в ODBC-строку они не попадают (см. BuildODBCConnectString в
  // FireDAC.Phys.ODBCBase.pas). Kлюч ODBCDriver/ODBCAdvanced — исключение:
  // FireDAC дописывает его содержимое в строку подключения как есть.
  FCon.Params.Add('ODBCAdvanced=TrustServerCertificate=Yes;Connection Timeout=15');
end;

procedure TDM.Connect;
begin
  if FCon.Connected then
    Exit;                       // уже подключены — ничего не делаем
  ApplyConnectionParams;
  FCon.Connected := True;
end;

procedure TDM.Disconnect;
begin
  if FQry.Active then FQry.Close;
  if FQryStock.Active then FQryStock.Close;
  if FQryGoods.Active then FQryGoods.Close;
  if FQryWarehouses.Active then FQryWarehouses.Close;
  if FQryPlaces.Active then FQryPlaces.Close;
  if FQryBatches.Active then FQryBatches.Close;
  if FQryDocuments.Active then FQryDocuments.Close;
  if FQryDocLines.Active then FQryDocLines.Close;
  if FCon.Connected then FCon.Connected := False;
end;

function TDM.IsConnected: Boolean;
begin
  Result := FCon.Connected;
end;

function TDM.ServerVersion: string;
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'SELECT @@VERSION AS Ver';
  FQry.Open;
  Result := FQry.FieldByName('Ver').AsString;
  FQry.Close;
end;

function TDM.StockOnDate(const ATarget: TDateTime): TDataSet;
begin
  Connect;
  FQryStock.Close;
  // Вызов хранимой процедуры параметризованно: конкатенации дат нет (II.4).
  FQryStock.SQL.Clear;
  FQryStock.SQL.Add('EXEC dbo.usp_StockOnDate :ATarget');
  FQryStock.ParamByName('ATarget').DataType := ftDateTime;
  FQryStock.ParamByName('ATarget').AsDateTime := ATarget;
  FQryStock.Open;
  Result := FQryStock;
end;

function TDM.SafeSort(const ASortBy: string;
  const AAllowed: array of string; const ADefault: string): string;
var
  Col, Dir: string;
  Space: Integer;
  Allowed: string;
  Found: Boolean;
begin
  Result := ADefault;
  if ASortBy.Trim = '' then
    Exit;
  // Разбиваем «GoodsName DESC» на колонку и направление.
  Col := ASortBy.Trim;
  Dir := 'ASC';
  Space := Col.LastIndexOf(' ');
  if Space >= 0 then
  begin
    Dir := UpperCase(Col.Substring(Space + 1).Trim);
    Col := Col.Substring(0, Space).Trim;
    if (Dir <> 'ASC') and (Dir <> 'DESC') then
      Exit;                       // направление вне списка — откат к умолчанию
  end;
  Found := False;
  for Allowed in AAllowed do
    if SameText(Allowed, Col) then
    begin
      Found := True;
      Break;
    end;
  if Found then
    Result := Col + ' ' + Dir;
end;

// LIKE-шаблон из пользовательской подстроки: спецсимволы LIKE
// (% _ [) экранируются, чтобы поиск «100%» не совался со всеми строками.
function LikePattern(const AFilter: string): string;
begin
  Result := '%' +
    StringReplace(StringReplace(StringReplace(AFilter.Trim,
      '[', '[[]', [rfReplaceAll]),
      '%', '[%]', [rfReplaceAll]),
      '_', '[_]', [rfReplaceAll]) + '%';
end;

function TDM.OpenGoods(const ASortBy, AFilter: string): TDataSet;
begin
  Connect;
  FQryGoods.Close;
  FQryGoods.SQL.Text :=
    'SELECT GoodsId, GoodsName FROM dbo.Goods';
  if AFilter.Trim <> '' then
  begin
    FQryGoods.SQL.Add('WHERE GoodsName LIKE :Filter');
    FQryGoods.ParamByName('Filter').DataType := ftWideString;
    FQryGoods.ParamByName('Filter').AsString := LikePattern(AFilter);
  end;
  FQryGoods.SQL.Add('ORDER BY ' + SafeSort(ASortBy,
    ['GoodsId', 'GoodsName'], 'GoodsName'));
  FQryGoods.Open;
  Result := FQryGoods;
end;

function TDM.OpenWarehouses(const ASortBy, AFilter: string): TDataSet;
begin
  Connect;
  FQryWarehouses.Close;
  FQryWarehouses.SQL.Text :=
    'SELECT WarehouseId, WarehouseName FROM dbo.Warehouse';
  if AFilter.Trim <> '' then
  begin
    FQryWarehouses.SQL.Add('WHERE WarehouseName LIKE :Filter');
    FQryWarehouses.ParamByName('Filter').DataType := ftWideString;
    FQryWarehouses.ParamByName('Filter').AsString := LikePattern(AFilter);
  end;
  FQryWarehouses.SQL.Add('ORDER BY ' + SafeSort(ASortBy,
    ['WarehouseId', 'WarehouseName'], 'WarehouseName'));
  FQryWarehouses.Open;
  Result := FQryWarehouses;
end;

function TDM.OpenPlaces(const ASortBy, AFilter: string): TDataSet;
begin
  Connect;
  FQryPlaces.Close;
  FQryPlaces.SQL.Text :=
    'SELECT p.PlaceId, p.PlaceName, p.WarehouseId, w.WarehouseName ' +
    'FROM dbo.Place p JOIN dbo.Warehouse w ON w.WarehouseId = p.WarehouseId';
  if AFilter.Trim <> '' then
  begin
    // Ищем и по названию места, и по названию склада: оператор помнит
    // либо «А-1-3», либо «Центральный», но не всегда связку целиком.
    FQryPlaces.SQL.Add('WHERE p.PlaceName LIKE :Filter OR w.WarehouseName LIKE :Filter');
    FQryPlaces.ParamByName('Filter').DataType := ftWideString;
    FQryPlaces.ParamByName('Filter').AsString := LikePattern(AFilter);
  end;
  FQryPlaces.SQL.Add('ORDER BY ' + SafeSort(ASortBy,
    ['PlaceId', 'PlaceName', 'WarehouseId', 'WarehouseName'],
    'w.WarehouseName, p.PlaceName'));
  FQryPlaces.Open;
  Result := FQryPlaces;
end;

// ============================================================================
// CRUD: Товары
// ============================================================================

function TDM.GoodsAdd(const AGoodsName: string): Integer;
begin
  Connect;
  FQry.Close;
  // OUTPUT INSERTED вместо отдельного SELECT SCOPE_IDENTITY(): одна инструкция,
  // один вызов Open. Иначе INSERT ушёл бы дважды (ExecSQL + Open).
  FQry.SQL.Text := 'INSERT INTO dbo.Goods (GoodsName) OUTPUT INSERTED.GoodsId VALUES (:Name)';
  FQry.ParamByName('Name').AsString := AGoodsName;
  FQry.Open;
  Result := FQry.FieldByName('GoodsId').AsInteger;
  FQry.Close;
end;

procedure TDM.GoodsUpdate(AGoodsId: Integer; const AGoodsName: string);
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'UPDATE dbo.Goods SET GoodsName = :Name WHERE GoodsId = :Id';
  FQry.ParamByName('Name').AsString := AGoodsName;
  FQry.ParamByName('Id').AsInteger := AGoodsId;
  FQry.ExecSQL;
end;

procedure TDM.GoodsDelete(AGoodsId: Integer);
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'DELETE FROM dbo.Goods WHERE GoodsId = :Id';
  FQry.ParamByName('Id').AsInteger := AGoodsId;
  FQry.ExecSQL;
end;

// ============================================================================
// CRUD: Склады
// ============================================================================

function TDM.WarehouseAdd(const AWarehouseName: string): Integer;
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'INSERT INTO dbo.Warehouse (WarehouseName) OUTPUT INSERTED.WarehouseId VALUES (:Name)';
  FQry.ParamByName('Name').AsString := AWarehouseName;
  FQry.Open;
  Result := FQry.FieldByName('WarehouseId').AsInteger;
  FQry.Close;
end;

procedure TDM.WarehouseUpdate(AWarehouseId: Integer; const AWarehouseName: string);
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'UPDATE dbo.Warehouse SET WarehouseName = :Name WHERE WarehouseId = :Id';
  FQry.ParamByName('Name').AsString := AWarehouseName;
  FQry.ParamByName('Id').AsInteger := AWarehouseId;
  FQry.ExecSQL;
end;

procedure TDM.WarehouseDelete(AWarehouseId: Integer);
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'DELETE FROM dbo.Warehouse WHERE WarehouseId = :Id';
  FQry.ParamByName('Id').AsInteger := AWarehouseId;
  FQry.ExecSQL;
end;

// ============================================================================
// CRUD: Места
// ============================================================================

function TDM.PlaceAdd(AWarehouseId: Integer; const APlaceName: string): Integer;
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text :=
    'INSERT INTO dbo.Place (WarehouseId, PlaceName) OUTPUT INSERTED.PlaceId VALUES (:WId, :Name)';
  FQry.ParamByName('WId').AsInteger := AWarehouseId;
  FQry.ParamByName('Name').AsString := APlaceName;
  FQry.Open;
  Result := FQry.FieldByName('PlaceId').AsInteger;
  FQry.Close;
end;

procedure TDM.PlaceUpdate(APlaceId: Integer; AWarehouseId: Integer; const APlaceName: string);
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text :=
    'UPDATE dbo.Place SET WarehouseId = :WId, PlaceName = :Name WHERE PlaceId = :Id';
  FQry.ParamByName('WId').AsInteger := AWarehouseId;
  FQry.ParamByName('Name').AsString := APlaceName;
  FQry.ParamByName('Id').AsInteger := APlaceId;
  FQry.ExecSQL;
end;

procedure TDM.PlaceDelete(APlaceId: Integer);
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'DELETE FROM dbo.Place WHERE PlaceId = :Id';
  FQry.ParamByName('Id').AsInteger := APlaceId;
  FQry.ExecSQL;
end;

// ============================================================================
// Курсоры справочников: общее сохранение/восстановление
//
// Без MARS (для MSSQL-драйвера FireDAC его не включают) на одном соединении
// живёт один активный серверный курсор. Гриды справочников держат курсоры
// открытыми, поэтому на время транзакции их закрывают, а после — обязаны
// вернуть в прежнее состояние, иначе вкладки опустеют.
// ============================================================================

procedure TDM.SaveAndCloseDictCursors(out AState: TDictCursorState);
begin
  AState.Goods := FQryGoods.Active;
  AState.Warehouses := FQryWarehouses.Active;
  AState.Places := FQryPlaces.Active;
  AState.Batches := FQryBatches.Active;
  AState.Documents := FQryDocuments.Active;
  AState.DocLines := FQryDocLines.Active;
  if AState.Goods then FQryGoods.Close;
  if AState.Warehouses then FQryWarehouses.Close;
  if AState.Places then FQryPlaces.Close;
  if AState.Batches then FQryBatches.Close;
  if AState.Documents then FQryDocuments.Close;
  if AState.DocLines then FQryDocLines.Close;
end;

procedure TDM.RestoreDictCursors(const AState: TDictCursorState);
begin
  if AState.Goods then FQryGoods.Open;
  if AState.Warehouses then FQryWarehouses.Open;
  if AState.Places then FQryPlaces.Open;
  if AState.Batches then FQryBatches.Open;
  if AState.Documents then FQryDocuments.Open;
  if AState.DocLines then FQryDocLines.Open;
end;

// ============================================================================
// Приходный документ (SPECIFICATION.md II.2.3)
// ============================================================================

function TDM.DocumentIncome(AGoodsId, APlaceId: Int64; AQnty, APrice: Extended;
  ADocDate, AExpiryDate: TDateTime; const AComment: string): Integer;
var
  DocId, BatchId: Int64;
  DictState: TDictCursorState;
begin
  Connect;
  SaveAndCloseDictCursors(DictState);

  // Внешняя try/finally возвращает курсоры при любом исходе; внутренняя
  // try/except откатывает транзакцию. В Delphi нельзя совместить except и
  // finally в одном блоке, поэтому блоки вложенные.
  try
    FTransaction.StartTransaction;
    try
    // 1. Batch — партия создаётся сразу, Quantity сразу итоговый.
    FQry.Close;
    FQry.SQL.Text :=
      'INSERT INTO dbo.Batch (GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate) ' +
      'OUTPUT INSERTED.BatchId VALUES (:GoodsId, :PlaceId, :Qty, :Price, :IncomeDate, :Expiry)';
    FQry.ParamByName('GoodsId').AsLargeInt := AGoodsId;
    FQry.ParamByName('PlaceId').AsLargeInt := APlaceId;
    FQry.ParamByName('Qty').AsExtended := AQnty;
    FQry.ParamByName('Price').AsExtended := APrice;
    FQry.ParamByName('IncomeDate').AsDateTime := ADocDate;
    // DataType задаём до Null — иначе MSSQL-335.
    FQry.ParamByName('Expiry').DataType := ftDate;
    if AExpiryDate <= 0 then
      FQry.ParamByName('Expiry').Value := Null
    else
      FQry.ParamByName('Expiry').AsDateTime := AExpiryDate;
    FQry.Open;
    BatchId := FQry.FieldByName('BatchId').AsLargeInt;
    FQry.Close;

    // 2. Document (DocType = 1 = Приход)
    FQry.SQL.Text :=
      'INSERT INTO dbo.Document (DocType, DocDate, [Comment]) ' +
      'OUTPUT INSERTED.DocumentId VALUES (1, :DocDate, :Comment)';
    FQry.ParamByName('DocDate').AsDateTime := ADocDate;
    // DataType для Comment — NVARCHAR(255): обязателен ftWideString.
    // С ftString параметр уходит как SQL_VARCHAR, ODBC перекодирует его
    // через однобайтовую кодировку, и кириллица сохраняется как «?????».
    // Значение Null — только после установки DataType (MSSQL-335).
    FQry.ParamByName('Comment').DataType := ftWideString;
    if AComment <> '' then
      FQry.ParamByName('Comment').AsString := AComment
    else
      FQry.ParamByName('Comment').Value := Null;
    FQry.Open;
    DocId := FQry.FieldByName('DocumentId').AsLargeInt;
    FQry.Close;

    // 3. DocumentLine: на приходе BatchId уже известен, место — «куда»
    FQry.SQL.Text :=
      'INSERT INTO dbo.DocumentLine (DocumentId, BatchId, GoodsId, PlaceToId, Quantity, Price) ' +
      'VALUES (:DocId, :BatchId, :GoodsId, :PlaceId, :Qty, :Price)';
    FQry.ParamByName('DocId').AsLargeInt := DocId;
    FQry.ParamByName('BatchId').AsLargeInt := BatchId;
    FQry.ParamByName('GoodsId').AsLargeInt := AGoodsId;
    FQry.ParamByName('PlaceId').AsLargeInt := APlaceId;
    FQry.ParamByName('Qty').AsExtended := AQnty;
    FQry.ParamByName('Price').AsExtended := APrice;
    FQry.ExecSQL;

    // 4. StockMovement (+). MovementDate = дата документа, не текущая:
    //    иначе отчёт «на дату» не воспроизвёл бы прошлое.
    FQry.SQL.Text :=
      'INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate, DocumentId) ' +
      'VALUES (:BatchId, :PlaceId, :Qty, :DocDate, :DocId)';
    FQry.ParamByName('BatchId').AsLargeInt := BatchId;
    FQry.ParamByName('PlaceId').AsLargeInt := APlaceId;
    FQry.ParamByName('Qty').AsExtended := AQnty;
    FQry.ParamByName('DocDate').AsDateTime := ADocDate;
    FQry.ParamByName('DocId').AsLargeInt := DocId;
    FQry.ExecSQL;

    FTransaction.Commit;
    Result := DocId;
  except
    FTransaction.Rollback;
    raise;                       // сообщение уходит вызывающему, в статус формы
  end;
finally
  // Курсоры возвращаем в любом случае — даже при ошибке интерфейс должен
  // оставаться рабочим. Без finally курсоры «зависали» бы закрытыми.
  RestoreDictCursors(DictState);
end;
end;

// ============================================================================
// Расходный документ (SPECIFICATION.md II.2.3)
// ============================================================================

// Общий движок списания. ATakes — уже готовые «партия + количество»:
// ручный режим передаёт одну строку, FIFO — несколько. Курсоры справочников
// здесь НЕ трогаются: вызывающий обязан закрыть их до и восстановить после
// (FIFO читает список партий, и этому чтению тоже нужно свободное соединение).
function TDM.DoOutcome(const ATakes: array of TBatchTake; ADocDate: TDateTime;
  const AComment: string): Integer;
var
  i: Integer;
  DocId: Int64;
begin
  if Length(ATakes) = 0 then
    raise Exception.Create('Нечего списывать: пустой список партий');

  FTransaction.StartTransaction;
  try
    // 1. Document (DocType = 3 = Расход)
    FQry.Close;
    FQry.SQL.Text :=
      'INSERT INTO dbo.Document (DocType, DocDate, [Comment]) ' +
      'OUTPUT INSERTED.DocumentId VALUES (3, :DocDate, :Comment)';
    FQry.ParamByName('DocDate').AsDateTime := ADocDate;
    // ftWideString до Null — иначе MSSQL-335; ftString вместо WideString
    // перекодировал бы кириллицу комментария в «?????» (см. DocumentIncome).
    FQry.ParamByName('Comment').DataType := ftWideString;
    if AComment <> '' then
      FQry.ParamByName('Comment').AsString := AComment
    else
      FQry.ParamByName('Comment').Value := Null;
    FQry.Open;
    DocId := FQry.FieldByName('DocumentId').AsLargeInt;
    FQry.Close;

    for i := 0 to High(ATakes) do
    begin
      // 2. DocumentLine: расход — место «откуда», цена из партии
      FQry.SQL.Text :=
        'INSERT INTO dbo.DocumentLine (DocumentId, BatchId, GoodsId, PlaceFromId, Quantity, Price) ' +
        'VALUES (:DocId, :BatchId, :GoodsId, :PlaceId, :Qty, :Price)';
      FQry.ParamByName('DocId').AsLargeInt := DocId;
      FQry.ParamByName('BatchId').AsLargeInt := ATakes[i].BatchId;
      FQry.ParamByName('GoodsId').AsLargeInt := ATakes[i].GoodsId;
      FQry.ParamByName('PlaceId').AsLargeInt := ATakes[i].PlaceId;
      FQry.ParamByName('Qty').AsExtended := ATakes[i].Qty;
      FQry.ParamByName('Price').AsExtended := ATakes[i].Price;
      FQry.ExecSQL;

      // 3. StockMovement (−). Знак задаётся здесь, в БД хранится как есть:
      //    отчёт суммирует Quantity, поэтому минус = списание.
      FQry.SQL.Text :=
        'INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate, DocumentId) ' +
        'VALUES (:BatchId, :PlaceId, :Qty, :DocDate, :DocId)';
      FQry.ParamByName('BatchId').AsLargeInt := ATakes[i].BatchId;
      FQry.ParamByName('PlaceId').AsLargeInt := ATakes[i].PlaceId;
      FQry.ParamByName('Qty').AsExtended := -ATakes[i].Qty;
      FQry.ParamByName('DocDate').AsDateTime := ADocDate;
      FQry.ParamByName('DocId').AsLargeInt := DocId;
      FQry.ExecSQL;

      // 4. Остаток партии. UPDATE с защитой: Quantity не может уйти в минус
      //    (двойной CK_Batch_Quantity в БД, но здесь условие даёт понятную
      //    ошибку вместо молчаливого «ничего не обновилось»).
      FQry.SQL.Text :=
        'UPDATE dbo.Batch SET Quantity = Quantity - :Qty ' +
        'WHERE BatchId = :BatchId AND Quantity >= :Qty2';
      FQry.ParamByName('Qty').AsExtended := ATakes[i].Qty;
      FQry.ParamByName('BatchId').AsLargeInt := ATakes[i].BatchId;
      FQry.ParamByName('Qty2').AsExtended := ATakes[i].Qty;
      FQry.ExecSQL;
      if FQry.RowsAffected = 0 then
        raise Exception.CreateFmt(
          'Партия %d: недостаточно остатка для списания', [ATakes[i].BatchId]);
    end;

    FTransaction.Commit;
    Result := DocId;
  except
    FTransaction.Rollback;
    raise;
  end;
end;

function TDM.OpenBatchesForGoods(AGoodsId: Int64;
  AShowZero: Boolean): TDataSet;
begin
  Connect;
  FQryBatches.Close;
  // Остаток партии = сумма всех движений (регистр — точка истины, см. II.2.4).
  // Порядок IncomeDate ASC = FIFO: первая строка — самая старая партия.
  FQryBatches.SQL.Clear;
  FQryBatches.SQL.Text :=
    'SELECT b.BatchId, g.GoodsName, p.PlaceName, w.WarehouseId, w.WarehouseName, ' +
    ' b.IncomeDate, b.Price, ISNULL(SUM(m.Quantity), 0) AS QtyLeft ' +
    'FROM dbo.Batch b ' +
    'JOIN dbo.Goods g ON g.GoodsId = b.GoodsId ' +
    'JOIN dbo.Place p ON p.PlaceId = b.PlaceId ' +
    'JOIN dbo.Warehouse w ON w.WarehouseId = p.WarehouseId ' +
    'LEFT JOIN dbo.StockMovement m ON m.BatchId = b.BatchId ' +
    'WHERE b.GoodsId = :Gid ' +
    'GROUP BY b.BatchId, g.GoodsName, p.PlaceName, w.WarehouseId, w.WarehouseName, ' +
    ' b.IncomeDate, b.Price ' +
    // AShowZero: израсходованные партии остаются в списке (с нулём), иначе
    // строка просто исчезает и пользователь думает, что данные потерялись.
    'HAVING ISNULL(SUM(m.Quantity), 0) ' + IfThen(AShowZero, '>=', '>') + ' 0 ' +
    // BatchId вторым ключом: у партий бывает одинаковая IncomeDate (в один
    // день привезли два раза), и без него порядок FIFO не воспроизводим —
    // SQL Server вправе вернуть равные строки в любом порядке.
    'ORDER BY b.IncomeDate, b.BatchId';
  FQryBatches.ParamByName('Gid').DataType := ftLargeInt;
  FQryBatches.ParamByName('Gid').AsLargeInt := AGoodsId;
  FQryBatches.Open;
  Result := FQryBatches;
end;

function TDM.DocumentOutcomeManual(ABatchId: Int64; AQnty: Extended;
  ADocDate: TDateTime; const AComment: string): Integer;
var
  Take: TBatchTake;
  DictState: TDictCursorState;
begin
  Connect;
  SaveAndCloseDictCursors(DictState);
  try
    // Партию читаем здесь же: GoodsId и PlaceId для строк документа берутся
    // из неё, отдельная выборка не нужна.
    FQry.Close;
    FQry.SQL.Text :=
      'SELECT GoodsId, PlaceId, Quantity, Price FROM dbo.Batch WHERE BatchId = :Id';
    FQry.ParamByName('Id').AsLargeInt := ABatchId;
    FQry.Open;
    if FQry.IsEmpty then
    begin
      FQry.Close;
      raise Exception.CreateFmt('Партия %d не найдена', [ABatchId]);
    end;
    Take.BatchId := ABatchId;
    Take.GoodsId := FQry.FieldByName('GoodsId').AsLargeInt;
    Take.PlaceId := FQry.FieldByName('PlaceId').AsLargeInt;
    Take.Price := FQry.FieldByName('Price').AsExtended;
    if AQnty > FQry.FieldByName('Quantity').AsExtended then
    begin
      FQry.Close;
      raise Exception.CreateFmt(
        'Нельзя списать %g: остаток партии всего %g',
        [AQnty, FQry.FieldByName('Quantity').AsExtended]);
    end;
    FQry.Close;
    Take.Qty := AQnty;
    Result := DoOutcome([Take], ADocDate, AComment);
  finally
    RestoreDictCursors(DictState);
  end;
end;

function TDM.DocumentOutcomeFIFO(AGoodsId, AWarehouseId: Int64; AQnty: Extended;
  ADocDate: TDateTime; const AComment: string): Integer;
var
  Takes: TArray<TBatchTake>;
  Take: TBatchTake;
  Remaining: Extended;
  DictState: TDictCursorState;

  // Источниковое SQL для набора FIFO: тот же запрос, что в OpenBatchesForGoods,
  // но с фильтром склада. Собираем в массив TBatchTake — транзакция не должна
  // держать открытый курсор во время записи (один курсор на соединение).
  procedure Collect;
  var
    Idx: Integer;
    Qty: Extended;
  begin
    SetLength(Takes, 0);
    FQry.Close;
    FQry.SQL.Text :=
      'SELECT b.BatchId, b.GoodsId, b.PlaceId, b.Price, ISNULL(SUM(m.Quantity), 0) AS QtyLeft ' +
      'FROM dbo.Batch b ' +
      'JOIN dbo.Place p ON p.PlaceId = b.PlaceId ' +
      'LEFT JOIN dbo.StockMovement m ON m.BatchId = b.BatchId ' +
      'WHERE b.GoodsId = :Gid';
    if AWarehouseId > 0 then
    begin
      FQry.SQL.Add(' AND p.WarehouseId = :Wid');
      FQry.ParamByName('Wid').DataType := ftLargeInt;
      FQry.ParamByName('Wid').AsLargeInt := AWarehouseId;
    end;
    FQry.SQL.Add(
      ' GROUP BY b.BatchId, b.GoodsId, b.PlaceId, b.Price, b.IncomeDate ' +
      ' HAVING ISNULL(SUM(m.Quantity), 0) > 0 ' +
      // BatchId — детерминированный тай-брейк для одинаковых IncomeDate.
      ' ORDER BY b.IncomeDate, b.BatchId');
    FQry.ParamByName('Gid').DataType := ftLargeInt;
    FQry.ParamByName('Gid').AsLargeInt := AGoodsId;
    FQry.Open;
    try
      FQry.First;
      while not FQry.Eof do
      begin
        Qty := FQry.FieldByName('QtyLeft').AsExtended;
        // Копейка остатка из-за DECIMAL-арифметики не должна порождать
        // пустую строку документа (CK_DocumentLine_Quantity: Quantity > 0).
        if (Remaining > 1e-9) and (Qty > 1e-9) then
        begin
          Take.BatchId := FQry.FieldByName('BatchId').AsLargeInt;
          Take.GoodsId := FQry.FieldByName('GoodsId').AsLargeInt;
          Take.PlaceId := FQry.FieldByName('PlaceId').AsLargeInt;
          Take.Price := FQry.FieldByName('Price').AsExtended;
          if Qty >= Remaining then
          begin
            Take.Qty := Remaining;
            Remaining := 0;
          end
          else
          begin
            Take.Qty := Qty;
            Remaining := Remaining - Qty;
          end;
          Idx := Length(Takes);
          SetLength(Takes, Idx + 1);
          Takes[Idx] := Take;
        end;
        FQry.Next;
      end;
    finally
      FQry.Close;
    end;
  end;

begin
  if AQnty <= 0 then
    raise Exception.Create('Количество списания должно быть больше нуля');
  Connect;
  SaveAndCloseDictCursors(DictState);
  try
    Remaining := AQnty;
    Collect;
    if Remaining > 1e-9 then
      raise Exception.CreateFmt(
        'Недостаточно остатка: не хватает %g шт (по FIFO списано бы %g)',
        [Remaining, AQnty - Remaining]);
    Result := DoOutcome(Takes, ADocDate, AComment);
  finally
    RestoreDictCursors(DictState);
  end;
end;

destructor TDM.Destroy;
begin
  Disconnect;
  inherited;
end;

// ============================================================================
// Реестр документов
// ============================================================================

function TDM.OpenDocuments(const AFrom, ATo: TDateTime;
  ADocType: Integer; const AFilter: string): TDataSet;
var
  Num: Int64;
begin
  Connect;
  FQryDocuments.Close;
  FQryDocuments.SQL.Clear;
  // Название типа — CASE в SQL: форма получает готовую строку и не знает
  // числовых кодов DocType. Литералы обязаны быть с префиксом N: поля
  // таблицы NVARCHAR, а без N константа приводится через кодовую страницу
  // сервера и кириллица превращается в «??????».
  FQryDocuments.SQL.Text :=
    'SELECT d.DocumentId, ' +
    ' CASE d.DocType WHEN 1 THEN N''Приход'' WHEN 2 THEN N''Перемещение'' ' +
    '  WHEN 3 THEN N''Расход'' END AS DocTypeName, ' +
    ' d.DocDate, d.[Comment], ' +
    ' COUNT(dl.LineId) AS LineCount, ' +
    ' SUM(dl.Quantity) AS TotalQty ' +
    'FROM dbo.Document d ' +
    'LEFT JOIN dbo.DocumentLine dl ON dl.DocumentId = d.DocumentId ' +
    // Полунеинтервал [From, To): форма передаёт «до конца суток» как
    // «начало следующих суток», поэтому <= отбросило бы документы последних
    // секунд дня.
    'WHERE d.DocDate >= :From AND d.DocDate < :To';
  if ADocType > 0 then
    FQryDocuments.SQL.Add(' AND d.DocType = :Type');
  // Поиск по реестру: комментарий, название типа; если ввели число —
  // ещё и номер документа (кладовщик чаще ищет «№145», чем дату).
  if AFilter.Trim <> '' then
  begin
    FQryDocuments.SQL.Add(' AND (d.[Comment] LIKE :Filter' +
      ' OR CASE d.DocType WHEN 1 THEN N''Приход'' WHEN 2 THEN N''Перемещение''' +
      ' WHEN 3 THEN N''Расход'' END LIKE :Filter');
    if TryStrToInt64(AFilter.Trim, Num) then
      FQryDocuments.SQL.Add(' OR d.DocumentId = ' + IntToStr(Num));
      // IntToStr безопасен: TryStrToInt64 гарантирует, что строка — число.
    FQryDocuments.SQL.Add(')');
    FQryDocuments.ParamByName('Filter').DataType := ftWideString;
    FQryDocuments.ParamByName('Filter').AsString := LikePattern(AFilter);
  end;
  FQryDocuments.SQL.Add(' GROUP BY d.DocumentId, d.DocType, d.DocDate, d.[Comment]');
  FQryDocuments.SQL.Add(' ORDER BY d.DocDate DESC, d.DocumentId DESC');
  FQryDocuments.ParamByName('From').DataType := ftDateTime;
  FQryDocuments.ParamByName('From').AsDateTime := AFrom;
  FQryDocuments.ParamByName('To').DataType := ftDateTime;
  FQryDocuments.ParamByName('To').AsDateTime := ATo;
  if ADocType > 0 then
  begin
    FQryDocuments.ParamByName('Type').DataType := ftSmallint;
    FQryDocuments.ParamByName('Type').AsSmallint := ADocType;
  end;
  FQryDocuments.Open;
  Result := FQryDocuments;
end;

// Строки документа — расшифровка шапки в реестре: из какой партии, сколько
// и по какой цене. LEFT JOIN на места: у прихода PlaceFromId пуст, у расхода
// пуст PlaceToId, и INNER JOIN выбросил бы половину строк.
function TDM.OpenDocumentLines(ADocumentId: Int64): TDataSet;
begin
  Connect;
  FQryDocLines.Close;
  FQryDocLines.SQL.Text :=
    'SELECT dl.BatchId, g.GoodsName, ' +
    ' pf.PlaceName AS PlaceFromName, pt.PlaceName AS PlaceToName, ' +
    ' dl.Quantity, dl.Price ' +
    'FROM dbo.DocumentLine dl ' +
    'JOIN dbo.Goods g ON g.GoodsId = dl.GoodsId ' +
    'LEFT JOIN dbo.Place pf ON pf.PlaceId = dl.PlaceFromId ' +
    'LEFT JOIN dbo.Place pt ON pt.PlaceId = dl.PlaceToId ' +
    'WHERE dl.DocumentId = :DocId ' +
    'ORDER BY dl.LineId';
  FQryDocLines.ParamByName('DocId').DataType := ftLargeInt;
  FQryDocLines.ParamByName('DocId').AsLargeInt := ADocumentId;
  FQryDocLines.Open;
  Result := FQryDocLines;
end;

// ============================================================================
// Peek: расчёт без записи (для диалога подтверждения)
//
// Контракт: при успехе возвращает текст для диалога («что будет списано»),
// при неудаче бросает Exception с понятной причиной. Форма ловит try/except:
// исключение = показать текст в статусе, строка = показать диалог подтверждения.
// ============================================================================

function TDM.PeekOutcomeFIFO(AGoodsId, AWarehouseId: Int64;
  AQnty: Extended): string;
var
  Remaining: Extended;
  QtyLeft: Extended;
  Parts: TArray<string>;
  N, i: Integer;
  S: string;
begin
  if AQnty <= 0 then
    raise Exception.Create('Количество должно быть больше нуля');
  Connect;
  FQry.Close;
  FQry.SQL.Text :=
    'SELECT b.BatchId, b.GoodsId, b.PlaceId, b.Price, ISNULL(SUM(m.Quantity), 0) AS QtyLeft ' +
    'FROM dbo.Batch b ' +
    'JOIN dbo.Place p ON p.PlaceId = b.PlaceId ' +
    'LEFT JOIN dbo.StockMovement m ON m.BatchId = b.BatchId ' +
    'WHERE b.GoodsId = :Gid';
  if AWarehouseId > 0 then
    FQry.SQL.Add(' AND p.WarehouseId = :Wid');
  FQry.SQL.Add(
    ' GROUP BY b.BatchId, b.GoodsId, b.PlaceId, b.Price, b.IncomeDate ' +
    ' HAVING ISNULL(SUM(m.Quantity), 0) > 0 ' +
    // BatchId — детерминированный тай-брейк для одинаковых IncomeDate.
    ' ORDER BY b.IncomeDate, b.BatchId');
  FQry.ParamByName('Gid').DataType := ftLargeInt;
  FQry.ParamByName('Gid').AsLargeInt := AGoodsId;
  if AWarehouseId > 0 then
  begin
    FQry.ParamByName('Wid').DataType := ftLargeInt;
    FQry.ParamByName('Wid').AsLargeInt := AWarehouseId;
  end;
  FQry.Open;
  try
    Remaining := AQnty;
    N := 0;
    SetLength(Parts, 0);
    while not FQry.Eof and (Remaining > 1e-9) do
    begin
      QtyLeft := FQry.FieldByName('QtyLeft').AsExtended;
      if QtyLeft <= 1e-9 then Break;
      // Память под строку выделяем ДО присваивания: Parts[N] при длине 0
      // бросает Range check error (это и была прежняя «авария предпросмотра»).
      SetLength(Parts, N + 1);
      if QtyLeft >= Remaining then
      begin
        // %d в Delphi RTL корректно принимает Int64 (tftInt64); %I64d —
        // формат C-рантайма, Delphi его не знает и бросает «invalid format».
        // Настоящий Range check error вызывал запись Parts[N] до SetLength.
        Parts[N] := Format('Партия %d -> %g', [
          FQry.FieldByName('BatchId').AsLargeInt, Remaining]);
        Remaining := 0;
      end
      else
      begin
        Parts[N] := Format('Партия %d -> все %g', [
          FQry.FieldByName('BatchId').AsLargeInt, QtyLeft]);
        Remaining := Remaining - QtyLeft;
      end;
      Inc(N);
      FQry.Next;
    end;
  finally
    FQry.Close;
  end;

  if N = 0 then
    raise Exception.Create('У товара нет партий с остатком');
  if Remaining > 1e-9 then
    raise Exception.Create(Format(
      'Недостаточно остатка: не хватает %g шт', [Remaining]));

  // Собираем список партий в строку через перенос: Join* в System.StrUtils
  // нет, а тащить ради одной операции целый юнит не стоит.
  S := '';
  for i := 0 to N - 1 do
  begin
    if i > 0 then
      S := S + sLineBreak + '  ';
    S := S + Parts[i];
  end;
  Result := Format('Будет списано %g шт:' + sLineBreak + '  %s', [AQnty, S]);
end;

function TDM.PeekOutcomeManual(ABatchId: Int64; AQnty: Extended): string;
var
  Qty: Extended;
begin
  if AQnty <= 0 then
    raise Exception.Create('Количество должно быть больше нуля');
  Connect;
  FQry.Close;
  FQry.SQL.Text := 'SELECT Quantity FROM dbo.Batch WHERE BatchId = :Id';
  FQry.ParamByName('Id').DataType := ftLargeInt;
  FQry.ParamByName('Id').AsLargeInt := ABatchId;
  FQry.Open;
  if FQry.IsEmpty then
  begin
    FQry.Close;
    raise Exception.Create('Партия ' + IntToStr(ABatchId) + ' не найдена');
  end;
  Qty := FQry.FieldByName('Quantity').AsExtended;
  FQry.Close;
  if AQnty > Qty then
    raise Exception.Create(Format(
      'Недостаточно остатка партии: есть %g, нужно %g', [Qty, AQnty]));
  Result := Format('Будет списано %g шт из партии %d (остаток партии: %g)',
    [AQnty, ABatchId, Qty]);
end;

// Суммарный остаток товара по всем складам (строка «Остаток: N шт» на форме).
function TDM.GoodsTotalLeft(AGoodsId: Int64): Extended;
begin
  Connect;
  FQry.Close;
  FQry.SQL.Text :=
    'SELECT ISNULL(SUM(m.Quantity), 0) AS Total ' +
    'FROM dbo.StockMovement m ' +
    'JOIN dbo.Batch b ON b.BatchId = m.BatchId ' +
    'WHERE b.GoodsId = :Gid';
  FQry.ParamByName('Gid').DataType := ftLargeInt;
  FQry.ParamByName('Gid').AsLargeInt := AGoodsId;
  FQry.Open;
  Result := FQry.FieldByName('Total').AsExtended;
  FQry.Close;
end;

// ============================================================================
// Перемещение партии между местами (SPECIFICATION.md II.2.3, DocType=2)
//
// Если переносится вся партия — меняем PlaceId у существующей строки Batch
// (иначе в таблице копятся партии с Quantity = 0).
// Если часть — партия расщепляется: новая Batch с ТЕМИ ЖЕ GoodsId, Price,
// IncomeDate и ExpiryDate, но другим PlaceId.
//
// IncomeDate обязан сохраняться: это ключ FIFO. Если подставить дату
// документа, перемещённая партия «помолодеет» и уедет в конец очереди
// списания — скоропорт перестанет списываться первым.
// ExpiryDate — иначе теряется срок годности.
// ============================================================================

function TDM.DocumentTransfer(ABatchId, ANewPlaceId: Int64;
  AQnty: Extended; ADocDate: TDateTime; const AComment: string): Integer;
var
  DocId, NewBatchId: Int64;
  GoodsId, OldPlaceId: Int64;
  Price, OldQty: Extended;
  IncomeDate: TDateTime;
  ExpiryDate: Variant;
  DictState: TDictCursorState;
begin
  if AQnty <= 0 then
    raise Exception.Create('Количество перемещения должно быть больше нуля');
  if ABatchId = ANewPlaceId then
    raise Exception.Create('Нельзя переместить на то же место');

  Connect;
  SaveAndCloseDictCursors(DictState);
  try
    // 1. Читаем старую партию целиком — переносить надо все её атрибуты.
    FQry.Close;
    FQry.SQL.Text :=
      'SELECT GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate ' +
      'FROM dbo.Batch WHERE BatchId = :Id';
    FQry.ParamByName('Id').AsLargeInt := ABatchId;
    FQry.Open;
    if FQry.IsEmpty then
    begin
      FQry.Close;
      raise Exception.Create('Партия не найдена');
    end;
    GoodsId := FQry.FieldByName('GoodsId').AsLargeInt;
    OldPlaceId := FQry.FieldByName('PlaceId').AsLargeInt;
    OldQty := FQry.FieldByName('Quantity').AsExtended;
    Price := FQry.FieldByName('Price').AsExtended;
    IncomeDate := FQry.FieldByName('IncomeDate').AsDateTime;
    ExpiryDate := FQry.FieldByName('ExpiryDate').Value;
    FQry.Close;

    if AQnty > OldQty then
      raise Exception.CreateFmt(
        'Нельзя переместить %g: в партии всего %g',
        [AQnty, OldQty]);

    // Полный перенос обрабатывается тем же путём, что и частичный:
    // старая партия обнуляется, новая создаётся с тем же набором атрибутов.

    FTransaction.StartTransaction;
    try
      // 2. Document (DocType = 2 = Перемещение).
      FQry.SQL.Text :=
        'INSERT INTO dbo.Document (DocType, DocDate, [Comment]) ' +
        'OUTPUT INSERTED.DocumentId VALUES (2, :DocDate, :Comment)';
      FQry.ParamByName('DocDate').AsDateTime := ADocDate;
      FQry.ParamByName('Comment').DataType := ftWideString;
      if AComment <> '' then
        FQry.ParamByName('Comment').AsString := AComment
      else
        FQry.ParamByName('Comment').Value := Null;
      FQry.Open;
      DocId := FQry.FieldByName('DocumentId').AsLargeInt;
      FQry.Close;

      // 3. DocumentLine: PlaceFromId и PlaceToId одновременно.
      FQry.SQL.Text :=
        'INSERT INTO dbo.DocumentLine ' +
        '(DocumentId, BatchId, GoodsId, PlaceFromId, PlaceToId, Quantity, Price) ' +
        'VALUES (:DocId, :BatchId, :GoodsId, :FromId, :ToId, :Qty, :Price)';
      FQry.ParamByName('DocId').AsLargeInt := DocId;
      FQry.ParamByName('BatchId').AsLargeInt := ABatchId;
      FQry.ParamByName('GoodsId').AsLargeInt := GoodsId;
      FQry.ParamByName('FromId').AsLargeInt := OldPlaceId;
      FQry.ParamByName('ToId').AsLargeInt := ANewPlaceId;
      FQry.ParamByName('Qty').AsExtended := AQnty;
      FQry.ParamByName('Price').AsExtended := Price;
      FQry.ExecSQL;

      // 4. StockMovement (−) — уход со старого места.
      FQry.SQL.Text :=
        'INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate, DocumentId) ' +
        'VALUES (:BatchId, :PlaceId, :Qty, :DocDate, :DocId)';
      FQry.ParamByName('BatchId').AsLargeInt := ABatchId;
      FQry.ParamByName('PlaceId').AsLargeInt := OldPlaceId;
      FQry.ParamByName('Qty').AsExtended := -AQnty;
      FQry.ParamByName('DocDate').AsDateTime := ADocDate;
      FQry.ParamByName('DocId').AsLargeInt := DocId;
      FQry.ExecSQL;

      // 5. Партия всегда расщепляется, даже при полном переносе.
      //    Причина: отчёт группирует остаток по PlaceId из StockMovement,
      //    а не из Batch. Если при полном переносе поменять Batch.PlaceId,
      //    движение «−» останется на старом месте и отчёт покажет там
      //    отрицательный остаток. Со старой партией Quantity = 0 сумма
      //    её движений равна нулю, и HAVING <> 0 её просто скрывает.
      FQry.SQL.Text :=
        'UPDATE dbo.Batch SET Quantity = Quantity - :Qty ' +
        'WHERE BatchId = :BatchId AND Quantity >= :Qty2';
      FQry.ParamByName('Qty').AsExtended := AQnty;
      FQry.ParamByName('BatchId').AsLargeInt := ABatchId;
      FQry.ParamByName('Qty2').AsExtended := AQnty;
      FQry.ExecSQL;
      if FQry.RowsAffected = 0 then
        raise Exception.Create('Партия: недостаточно остатка для перемещения');

      // Новая партия наследует цену, дату прихода и срок годности:
      // IncomeDate — ключ FIFO, и подставлять дату документа нельзя,
      // иначе перемещённая партия «помолодеет» и уедет в конец очереди.
      FQry.SQL.Text :=
        'INSERT INTO dbo.Batch (GoodsId, PlaceId, Quantity, Price, IncomeDate, ExpiryDate) ' +
        'OUTPUT INSERTED.BatchId ' +
        'VALUES (:GoodsId, :PlaceId, :Qty, :Price, :IncomeDate, :Expiry)';
      FQry.ParamByName('GoodsId').AsLargeInt := GoodsId;
      FQry.ParamByName('PlaceId').AsLargeInt := ANewPlaceId;
      FQry.ParamByName('Qty').AsExtended := AQnty;
      FQry.ParamByName('Price').AsExtended := Price;
      FQry.ParamByName('IncomeDate').AsDateTime := IncomeDate;
      // DataType до Value — иначе MSSQL-335 при Null.
      FQry.ParamByName('Expiry').DataType := ftDateTime;
      FQry.ParamByName('Expiry').Value := ExpiryDate;
      FQry.Open;
      NewBatchId := FQry.FieldByName('BatchId').AsLargeInt;
      FQry.Close;

      // 6. StockMovement (+) — приход на новое место.
      FQry.SQL.Text :=
        'INSERT INTO dbo.StockMovement (BatchId, PlaceId, Quantity, MovementDate, DocumentId) ' +
        'VALUES (:BatchId, :PlaceId, :Qty, :DocDate, :DocId)';
      FQry.ParamByName('BatchId').AsLargeInt := NewBatchId;
      FQry.ParamByName('PlaceId').AsLargeInt := ANewPlaceId;
      FQry.ParamByName('Qty').AsExtended := AQnty;
      FQry.ParamByName('DocDate').AsDateTime := ADocDate;
      FQry.ParamByName('DocId').AsLargeInt := DocId;
      FQry.ExecSQL;

      FTransaction.Commit;
      Result := DocId;
    except
      FTransaction.Rollback;
      raise;
    end;
  finally
    RestoreDictCursors(DictState);
  end;
end;

end.