unit MainForm;

{ ============================================================================
  Форма «Складской учёт» — CRUD справочников + отчёт «остатки на дату».

  Архитектура формы:
    TTabControl (вкладки: Остатки / Товары / Склады / Места)
      ├── Вкладка "Остатки" — TGrid с датасетом отчёта usp_StockOnDate
      ├── Вкладка "Товары"  — TGrid + кнопки CRUD (добавить/удалить)
      ├── Вкладка "Склады"  — TGrid + кнопки CRUD
      └── Вкладка "Места"   — TGrid + кнопки CRUD

  Все компоненты создаются кодом в конструкторе, .fmx — пустой каркас.
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.StrUtils,
  Data.DB,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls,
  FMX.Objects,          // TText
  FMX.Grid,             // TGrid
  FMX.Grid.Style,       // стили TGrid
  FMX.DateTimeCtrls,    // TDateEdit
  FMX.TabControl,       // TTabControl, TTabItem
  FMX.ListBox,          // TComboBox (в FMX он здесь, а не в FMX.StdCtrls)
  FMX.Edit,             // TEdit — количство и цена прихода
  FMX.DialogService,     // TDialogService: InputQuery, MessageDialog
  FMX.DialogService.Sync, // TDialogServiceSync: синхронный API
  FMX.Dialogs,           // mbYesNo, TMsgDlgType, TMsgDlgBtn
  Data.Bind.Components, // TBindingsList
  Data.Bind.DBScope,    // TBindSourceDB
  Data.Bind.Grid,       // TLinkGridToDataSource
  FMX.Bind.Grid,        // фабрика колонок FMX-гридов
  // Fmx.Bind.Editors обязателен, хотя его имён в коде нет: в секции
  // initialization этого юнита регистрируется TBindListGridEditor —
  // list control editor для TCustomGrid. Без него TLinkGridToDataSource при
  // активации привязки бросает EBindCompError «No list control editor
  // available for TGrid».
  Fmx.Bind.Editors,
  uDM;

type
  TFormMain = class(TForm)
  private
    // --- Вкладка "Остатки" ---
    FStockGrid: TGrid;
    FStockDate: TDateEdit;
    FStockTime: TTimeEdit;
    FStockBtn: TButton;
    FStockStatus: TText;
    FStockBindings: TBindingsList;
    FStockBindSource: TBindSourceDB;
    FStockLink: TLinkGridToDataSource;

    // --- Вкладки справочников ---
    FTabControl: TTabControl;
    // Разделы верхнего уровня: Операции / Справочники / Аналитика.
    // Восемь плоских вкладок в один ряд — это «всё на одной полке»:
    // товары соседствуют с приходом, хотя это разные рабочие сценарии.
    FTabOperations: TTabItem;
    FTabRefs: TTabItem;
    FTabAnalytics: TTabItem;
    FSubTabsOps: TTabControl;
    FSubTabsRefs: TTabControl;
    FSubTabsAnalytics: TTabControl;
    FTabStock: TTabItem;
    FTabGoods: TTabItem;
    FTabWarehouses: TTabItem;
    FTabPlaces: TTabItem;

    // --- Товары ---
    FGoodsGrid: TGrid;
    FGoodsBindings: TBindingsList;
    FGoodsBindSource: TBindSourceDB;
    FGoodsLink: TLinkGridToDataSource;
    FGoodsAddBtn: TButton;
    FGoodsEditBtn: TButton;
    FGoodsDelBtn: TButton;
    FGoodsStatus: TText;
    // Поиск и сортировка
    FGoodsSearch: TEdit;
    FGoodsSearchTimer: TTimer;
    FGoodsSort: string;          // «GoodsName» / «GoodsName DESC» ('' = по умолчанию)

    // --- Склады ---
    FWarehousesGrid: TGrid;
    FWarehousesBindings: TBindingsList;
    FWarehousesBindSource: TBindSourceDB;
    FWarehousesLink: TLinkGridToDataSource;
    FWarehousesAddBtn: TButton;
    FWarehousesEditBtn: TButton;
    FWarehousesDelBtn: TButton;
    FWarehousesStatus: TText;
    // Поиск и сортировка
    FWarehousesSearch: TEdit;
    FWarehousesSearchTimer: TTimer;
    FWarehousesSort: string;

    // --- Места ---
    FPlacesGrid: TGrid;
    FPlacesBindings: TBindingsList;
    FPlacesBindSource: TBindSourceDB;
    FPlacesLink: TLinkGridToDataSource;
    FPlacesAddBtn: TButton;
    FPlacesEditBtn: TButton;
    FPlacesDelBtn: TButton;
    FPlacesStatus: TText;
    // Поиск и сортировка
    FPlacesSearch: TEdit;
    FPlacesSearchTimer: TTimer;
    FPlacesSort: string;

    // --- Приход ---
    // Вкладка-форма ввода, а не таблица: документ создаётся одним нажатием,
    // строки в гриде редактировать нечего.
    FTabIncome: TTabItem;
    FIncomeGoodsCb: TComboBox;
    FIncomeWhCb: TComboBox;
    FIncomePlaceCb: TComboBox;
    FIncomeDate: TDateEdit;
    FIncomeTime: TTimeEdit;
    FIncomeQty: TEdit;
    FIncomePrice: TEdit;
    FIncomeExpiry: TDateEdit;
    FIncomeNoExpiry: TCheckBox;
    FIncomeComment: TEdit;
    FIncomeAddBtn: TButton;
    FIncomeStatus: TText;
    // ID, соответствующие строкам комбобоксов. TComboBox хранит только текст,
    // а в запрос идут именно ключи справочника.
    FGoodsIds: TArray<Int64>;
    FWhIds: TArray<Int64>;
    FPlaceIds: TArray<Int64>;   // места, отфильтрованные по выбранному складу
    FIncomePanel: TPanel;

    // --- Расход ---
    // Простая форма: товар, количество, дата/время, комментарий.
    // Галочка «Вручную» показывает поле номера партии. Перед списанием —
    // диалог подтверждения с расчётом (DM.PeekOutcome*).
    // Под формой — read-only список партий выбранного товара: по скрину
    // пользователь не понял, откуда берутся партии в диалоге, и попросил
    // показывать их сразу. Выделение строк не нужно — только чтение.
    FTabOutcome: TTabItem;
    FOutPanel: TPanel;
    FOutGoodsCb: TComboBox;
    FOutLeft: TText;            // «Остаток по товару: N шт»
    FOutManualCb: TCheckBox;    // «Вручную»
    FOutBatchNo: TEdit;         // номер партии (виден только в ручном режиме)
    FOutBatchNoLabel: TText;
    FOutQty: TEdit;
    FOutDate: TDateEdit;
    FOutTime: TTimeEdit;
    FOutComment: TEdit;
    FOutAddBtn: TButton;
    FOutStatus: TText;
    FOutGoodsIds: TArray<Int64>;
    FOutBatchGrid: TGrid;
    FOutBatchBindings: TBindingsList;
    FOutBatchBindSource: TBindSourceDB;
    FOutBatchLink: TLinkGridToDataSource;

    // --- Перемещение ---
    FTabTransfer: TTabItem;
    FTrPanel: TPanel;
    FTrGoodsCb: TComboBox;
    FTrGoodsIds: TArray<Int64>;
    FTrPicked: TText;           // «№10 · Б-2-1 · 49 шт» — что выбрано в гриде
    FTrSelBatchId: Int64;       // выбранная партия (0 = не выбрана)
    FTrSelQty: Extended;        // её остаток
    FTrPlaceCb: TComboBox;      // место назначения
    FTrPlaceIds: TArray<Int64>;
    FTrQty: TEdit;
    FTrDate: TDateEdit;
    FTrTime: TTimeEdit;
    FTrComment: TEdit;
    FTrAddBtn: TButton;
    FTrStatus: TText;
    // Все партии товара: видно, что и откуда можно переместить.
    FTrBatchGrid: TGrid;
    FTrBatchBindings: TBindingsList;
    FTrBatchBindSource: TBindSourceDB;
    FTrBatchLink: TLinkGridToDataSource;

    // --- Документы (реестр) ---
    FTabDocs: TTabItem;
    FDocPanel: TPanel;
    FDocTypeCb: TComboBox;      // Все / Приход / Перемещение / Расход
    FDocFrom: TDateEdit;
    FDocTo: TDateEdit;
    FDocSearch: TEdit;          // поиск по комментарию/типу/номеру
    FDocSearchTimer: TTimer;
    FDocRefreshBtn: TButton;
    FDocGrid: TGrid;
    FDocBindings: TBindingsList;
    FDocBindSource: TBindSourceDB;
    FDocLink: TLinkGridToDataSource;
    FDocStatus: TText;
    // Расшифровка выбранного документа: из какой партии что ушло/пришло.
    FLineGrid: TGrid;
    FLineBindings: TBindingsList;
    FLineBindSource: TBindSourceDB;
    FLineLink: TLinkGridToDataSource;
    FLineSplitter: TSplitter;
    FLineCaption: TText;

    // --- общие ---
    function ParseNum(const S: string; out V: Double): Boolean;
    function MakeLabel(const ACaption: string; AX, AY, AW: Single;
      AParent: TPanel): TText;
    procedure LoadStock(Sender: TObject);
    procedure LoadGoods;
    procedure LoadWarehouses;
    procedure LoadPlaces;
    procedure GoodsAddClick(Sender: TObject);
    procedure GoodsEditClick(Sender: TObject);
    procedure GoodsDeleteClick(Sender: TObject);
    procedure WarehousesAddClick(Sender: TObject);
    procedure WarehousesEditClick(Sender: TObject);
    procedure WarehousesDeleteClick(Sender: TObject);
    procedure PlacesAddClick(Sender: TObject);
    procedure PlacesEditClick(Sender: TObject);
    procedure PlacesDeleteClick(Sender: TObject);
    // Поиск и сортировка
    procedure GoodsSearchChange(Sender: TObject);
    procedure WarehousesSearchChange(Sender: TObject);
    procedure PlacesSearchChange(Sender: TObject);
    procedure DocsSearchChange(Sender: TObject);
    procedure SearchTimerTimer(Sender: TObject);
    procedure GoodsHeaderClick(Column: TColumn);
    procedure WarehousesHeaderClick(Column: TColumn);
    procedure PlacesHeaderClick(Column: TColumn);
    // Клик по заголовку: находит колонку в гриде, берёт MemberName из
    // привязки, переключает ASC/DESC, возвращает новое «Поле DESC» или ''.
    function NextSort(AGrid: TGrid; ALink: TLinkGridToDataSource;
      Column: TColumn; const ACurrent: string): string;
    // Подпись текущей сортировки («↑ Название» / «↓ Название» / '').
    function SortCaption(ALink: TLinkGridToDataSource;
      const ASort: string): string;
    procedure CreateStockColumns;
    procedure CreateGoodsColumns;
    procedure CreateWarehousesColumns;
    procedure CreatePlacesColumns;
    procedure CreateStockControls;
    procedure CreateGoodsControls;
    procedure CreateWarehousesControls;
    procedure CreatePlacesControls;

    // --- Приход ---
    procedure CreateIncomeControls;
    procedure FillIncomeCombos;
    procedure ApplyPlaceFilter;
    procedure IncomeAddClick(Sender: TObject);
    procedure IncomeWhCbChange(Sender: TObject);
    procedure IncomeNoExpiryChange(Sender: TObject);

    // --- Расход ---
    procedure CreateOutcomeControls;
    procedure CreateOutcomeBatchColumns;
    procedure ReloadOutcomeBatches;
    procedure FillOutcomeCombo;
    procedure OutcomeGoodsCbChange(Sender: TObject);
    procedure OutcomeManualCbChange(Sender: TObject);
    procedure OutcomeAddClick(Sender: TObject);

    // --- Документы (реестр) ---
    procedure CreateDocsControls;
    procedure CreateDocsColumns;
    procedure CreateLineColumns;
    procedure LoadDocs(Sender: TObject);
    procedure LoadDocumentLines(Sender: TObject; const ACol, ARow: Integer;
      var CanSelect: Boolean);

    // --- Перемещение ---
    procedure CreateTransferControls;
    procedure CreateTransferBatchColumns;
    procedure FillTransferCombos;
    procedure TransferGoodsCbChange(Sender: TObject);
    procedure TransferBatchSelected(Sender: TObject; const ACol, ARow: Integer;
      var CanSelect: Boolean);
    procedure TransferAddClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.fmx}

constructor TFormMain.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := 'Складской учёт';
  ClientWidth := 1000;
  ClientHeight := 700;
  Position := TFormPosition.ScreenCenter;

  // ========================================================================
  // Двухуровневая навигация: раздел → подвкладки.
  //
  //   Операции     Приход | Расход | Перемещение | Журнал документов
  //   Справочники  Товары | Склады | Места
  //   Аналитика    Остатки на дату
  //
  // Механика та же, что и раньше (TTabControl.ActiveTab): вложенный
  // TTabControl — стандартный контейнер, а не самодельная навигация.
  // ========================================================================
  FTabControl := TTabControl.Create(Self);
  FTabControl.Parent := Self;
  FTabControl.Align := TAlignLayout.Client;
  FTabControl.TabPosition := TTabPosition.Top;

  FTabOperations := TTabItem.Create(Self);
  FTabOperations.Parent := FTabControl;
  FTabOperations.Text := 'Операции';

  FTabRefs := TTabItem.Create(Self);
  FTabRefs.Parent := FTabControl;
  FTabRefs.Text := 'Справочники';

  FTabAnalytics := TTabItem.Create(Self);
  FTabAnalytics.Parent := FTabControl;
  FTabAnalytics.Text := 'Аналитика';

  // --- Операции ---
  FSubTabsOps := TTabControl.Create(Self);
  FSubTabsOps.Parent := FTabOperations;
  FSubTabsOps.Align := TAlignLayout.Client;
  FSubTabsOps.TabPosition := TTabPosition.Top;

  // --- Справочники ---
  FSubTabsRefs := TTabControl.Create(Self);
  FSubTabsRefs.Parent := FTabRefs;
  FSubTabsRefs.Align := TAlignLayout.Client;
  FSubTabsRefs.TabPosition := TTabPosition.Top;

  // --- Аналитика ---
  FSubTabsAnalytics := TTabControl.Create(Self);
  FSubTabsAnalytics.Parent := FTabAnalytics;
  FSubTabsAnalytics.Align := TAlignLayout.Client;
  FSubTabsAnalytics.TabPosition := TTabPosition.Top;

  // --- Справочники: Товары / Склады / Места ---
  FTabGoods := TTabItem.Create(Self);
  FTabGoods.Parent := FSubTabsRefs;
  FTabGoods.Text := 'Товары';
  CreateGoodsControls;
  CreateGoodsColumns;

  FTabWarehouses := TTabItem.Create(Self);
  FTabWarehouses.Parent := FSubTabsRefs;
  FTabWarehouses.Text := 'Склады';
  CreateWarehousesControls;
  CreateWarehousesColumns;

  FTabPlaces := TTabItem.Create(Self);
  FTabPlaces.Parent := FSubTabsRefs;
  FTabPlaces.Text := 'Места';
  CreatePlacesControls;
  CreatePlacesColumns;

  // --- Аналитика: Остатки ---
  FTabStock := TTabItem.Create(Self);
  FTabStock.Parent := FSubTabsAnalytics;
  FTabStock.Text := 'Остатки на дату';
  CreateStockControls;
  CreateStockColumns;

  // --- Операции: Приход / Расход / Перемещение / Документы ---
  FTabIncome := TTabItem.Create(Self);
  FTabIncome.Parent := FSubTabsOps;
  FTabIncome.Text := 'Приход';
  CreateIncomeControls;

  FTabOutcome := TTabItem.Create(Self);
  FTabOutcome.Parent := FSubTabsOps;
  FTabOutcome.Text := 'Расход';
  CreateOutcomeControls;
  CreateOutcomeBatchColumns;

  FTabTransfer := TTabItem.Create(Self);
  FTabTransfer.Parent := FSubTabsOps;
  FTabTransfer.Text := 'Перемещение';
  CreateTransferControls;
  CreateTransferBatchColumns;

  FTabDocs := TTabItem.Create(Self);
  FTabDocs.Parent := FSubTabsOps;
  FTabDocs.Text := 'Журнал документов';
  CreateDocsControls;
  CreateDocsColumns;
  CreateLineColumns;

  // Стартовый экран — «Операции / Приход»: это первое, что делает кладовщик.
  FTabControl.ActiveTab := FTabOperations;
  FSubTabsOps.ActiveTab := FTabIncome;
  FSubTabsRefs.ActiveTab := FTabGoods;
  FSubTabsAnalytics.ActiveTab := FTabStock;
  LoadGoods;
  LoadWarehouses;
  LoadPlaces;
  // Комбобоксы прихода читают уже открытые курсоры справочников,
  // поэтому вызываются ПОСЛЕ Load*, а не до.
  FillIncomeCombos;
  FillOutcomeCombo;
  FillTransferCombos;
end;

// ============================================================================
// Вкладка "Остатки"
// ============================================================================

procedure TFormMain.CreateStockControls;
var
  Panel: TPanel;
begin
  // Нижняя панель управления
  Panel := TPanel.Create(Self);
  Panel.Parent := FTabStock;
  Panel.Align := TAlignLayout.Bottom;
  Panel.Height := 100;

  FStockDate := TDateEdit.Create(Self);
  FStockDate.Parent := Panel;
  FStockDate.Position.X := 10;
  FStockDate.Position.Y := 10;
  FStockDate.Width := 180;
  FStockDate.Date := Now;

  // Требование I.5 — остатки «на Дату и Время», поэтому отдельное поле
  // времени: без него отчёт отвечал только на «конец дня».
  FStockTime := TTimeEdit.Create(Self);
  FStockTime.Parent := Panel;
  FStockTime.Position.X := 200;
  FStockTime.Position.Y := 10;
  FStockTime.Width := 110;
  FStockTime.Time := EncodeTime(23, 59, 59, 0);

  FStockBtn := TButton.Create(Self);
  FStockBtn.Parent := Panel;
  FStockBtn.Position.X := 330;
  FStockBtn.Position.Y := 10;
  FStockBtn.Width := 160;
  FStockBtn.Text := 'Загрузить остатки';
  FStockBtn.OnClick := LoadStock;

  FStockStatus := TText.Create(Self);
  FStockStatus.Parent := Panel;
  FStockStatus.Position.X := 10;
  FStockStatus.Position.Y := 60;
  FStockStatus.Width := 700;
  FStockStatus.Text := 'Выберите дату и нажмите «Загрузить остатки»';

  // Грид
  FStockGrid := TGrid.Create(Self);
  FStockGrid.Parent := FTabStock;
  FStockGrid.Align := TAlignLayout.Client;
end;

procedure TFormMain.CreateStockColumns;
begin
  FStockBindings := TBindingsList.Create(Self);
  FStockBindSource := TBindSourceDB.Create(Self);
  FStockLink := TLinkGridToDataSource.Create(Self);
  FStockLink.GridControl := FStockGrid;
  FStockLink.DataSource := FStockBindSource;

  with FStockLink.Columns.Add do
  begin
    MemberName := 'GoodsName';
    Header     := 'Товар';
    Width      := 150;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName := 'BatchId';
    Header     := 'Партия';
    Width      := 60;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName := 'WarehouseName';
    Header     := 'Склад';
    Width      := 130;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName := 'PlaceName';
    Header     := 'Место';
    Width      := 80;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName := 'IncomeDate';
    Header     := 'Приход';
    Width      := 120;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName := 'ExpiryDate';
    Header     := 'Срок';
    Width      := 120;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName     := 'Price';
    Header         := 'Цена';
    Width          := 80;
    DecimalDigits  := 2;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName     := 'Qty';
    Header         := 'Кол-во';
    Width          := 80;
    DecimalDigits  := 3;
  end;
  with FStockLink.Columns.Add do
  begin
    MemberName     := 'Sum';
    Header         := 'Сумма';
    Width          := 100;
    DecimalDigits  := 2;
  end;
end;

procedure TFormMain.LoadStock(Sender: TObject);
var
  DS: TDataSet;
  Moment: TDateTime;
begin
  try
    // Дата + время из двух полей — ровно то, что требует задание:
    // отчёт на произвольный момент, а не только на конец дня.
    Moment := Trunc(FStockDate.Date) + FStockTime.Time;
    // Перед новым вызовом StockOnDate нужно закрыть старый датасет, иначе
    // TFDQuery остаётся «висящим» — при повторном нажатии «Загрузить остатки»
    // на другую дату старый датасет не освободится.
    if FStockBindSource.DataSet <> nil then
      FStockBindSource.DataSet.Close;
    DS := DM.StockOnDate(Moment);
    FStockBindSource.DataSet := DS;
    if DS.RecordCount = 0 then
      FStockStatus.Text := Format('На %s остатков нет',
        [FormatDateTime('dd.mm.yyyy hh:nn', Moment)])
    else
      FStockStatus.Text := Format('На %s — %d строк',
        [FormatDateTime('dd.mm.yyyy hh:nn', Moment), DS.RecordCount]);
  except
    on E: Exception do
      FStockStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// ============================================================================
// Поиск и сортировка гридов справочников
//
// Идея: грид — «окно» в таблицу на тысячи строк. Два штатных средства:
//   * поле поиска -> серверный LIKE (строка фильтруется до передачи в грид);
//   * клик по заголовку -> серверный ORDER BY (FMX TGrid сам не сортирует).
// Текст колонки-заголовка и MemberName берём из привязки Link.Columns,
// порядок которых совпадает с порядком Grid.Columns (колонки создавались
// через Link.Columns.Add).
// ============================================================================

// Определяет, по какому полю привязки кликнули, и переключает направление:
// тот же столбец -> ASC <-> DESC, новый столбец -> ASC.
function TFormMain.NextSort(AGrid: TGrid; ALink: TLinkGridToDataSource;
  Column: TColumn; const ACurrent: string): string;
var
  i, Idx: Integer;
  Member, Field, Dir: string;
  Space: Integer;
begin
  Result := ACurrent;
  Idx := -1;
  for i := 0 to AGrid.ColumnCount - 1 do
    if AGrid.Columns[i] = Column then
    begin
      Idx := i;
      Break;
    end;
  if (Idx < 0) or (Idx >= ALink.Columns.Count) then
    Exit;
  Member := ALink.Columns[Idx].MemberName;

  Field := ACurrent;
  Dir := 'ASC';
  Space := Field.LastIndexOf(' ');
  if Space >= 0 then
  begin
    Dir := Field.Substring(Space + 1);
    Field := Field.Substring(0, Space);
  end;

  if SameText(Field, Member) and SameText(Dir, 'ASC') then
    Result := Member + ' DESC'
  else
    Result := Member + ' ASC';
end;

// Человекочитаемая подпись сортировки для статуса: «↑ Название».
function TFormMain.SortCaption(ALink: TLinkGridToDataSource;
  const ASort: string): string;
var
  i: Integer;
  Field, Dir: string;
  Space: Integer;
begin
  Result := '';
  if ASort = '' then
    Exit;
  Field := ASort;
  Dir := 'ASC';
  Space := Field.LastIndexOf(' ');
  if Space >= 0 then
  begin
    Dir := Field.Substring(Space + 1);
    Field := Field.Substring(0, Space);
  end;
  for i := 0 to ALink.Columns.Count - 1 do
    if SameText(ALink.Columns[i].MemberName, Field) then
    begin
      Result := Format('сортировка: %s%s',
        [IfThen(SameText(Dir, 'DESC'), '↓ ', '↑ '), ALink.Columns[i].Header]);
      Exit;
    end;
end;

// Ввод в поле поиска: не гонять запрос на каждый нажатый клавише.
// Таймер (350 мс) «догоняет» паузу печати; все три поля делят один
// обработчик — какой таймер сработал, определяется по Sender.
procedure TFormMain.GoodsSearchChange(Sender: TObject);
begin
  FGoodsSearchTimer.Enabled := False;
  FGoodsSearchTimer.Enabled := True;
end;

procedure TFormMain.WarehousesSearchChange(Sender: TObject);
begin
  FWarehousesSearchTimer.Enabled := False;
  FWarehousesSearchTimer.Enabled := True;
end;

procedure TFormMain.PlacesSearchChange(Sender: TObject);
begin
  FPlacesSearchTimer.Enabled := False;
  FPlacesSearchTimer.Enabled := True;
end;

procedure TFormMain.SearchTimerTimer(Sender: TObject);
begin
  TTimer(Sender).Enabled := False;
  if Sender = FGoodsSearchTimer then
    LoadGoods
  else if Sender = FWarehousesSearchTimer then
    LoadWarehouses
  else if Sender = FPlacesSearchTimer then
    LoadPlaces
  else if Sender = FDocSearchTimer then
    LoadDocs(nil);
end;

procedure TFormMain.DocsSearchChange(Sender: TObject);
begin
  FDocSearchTimer.Enabled := False;
  FDocSearchTimer.Enabled := True;
end;

procedure TFormMain.GoodsHeaderClick(Column: TColumn);
begin
  FGoodsSort := NextSort(FGoodsGrid, FGoodsLink, Column, FGoodsSort);
  LoadGoods;
end;

procedure TFormMain.WarehousesHeaderClick(Column: TColumn);
begin
  FWarehousesSort := NextSort(FWarehousesGrid, FWarehousesLink, Column,
    FWarehousesSort);
  LoadWarehouses;
end;

procedure TFormMain.PlacesHeaderClick(Column: TColumn);
begin
  FPlacesSort := NextSort(FPlacesGrid, FPlacesLink, Column, FPlacesSort);
  LoadPlaces;
end;

// ============================================================================
// Вкладка "Товары"
// ============================================================================

procedure TFormMain.CreateGoodsControls;
var
  Panel, SearchPanel: TPanel;
  SearchLabel: TText;
begin
  // --- Панель поиска над гридом ---
  SearchPanel := TPanel.Create(Self);
  SearchPanel.Parent := FTabGoods;
  SearchPanel.Align := TAlignLayout.Top;
  SearchPanel.Height := 40;

  SearchLabel := TText.Create(Self);
  SearchLabel.Parent := SearchPanel;
  SearchLabel.Position.X := 10;
  SearchLabel.Position.Y := 10;
  SearchLabel.Width := 40;
  SearchLabel.Height := 20;
  SearchLabel.Text := 'Поиск:';
  SearchLabel.VertTextAlign := TTextAlign.Leading;

  FGoodsSearch := TEdit.Create(Self);
  FGoodsSearch.Parent := SearchPanel;
  FGoodsSearch.Position.X := 55;
  FGoodsSearch.Position.Y := 8;
  FGoodsSearch.Width := 250;
  FGoodsSearch.TextPrompt := 'Введите текст и подождите...';
  FGoodsSearch.OnChange := GoodsSearchChange;

  FGoodsSearchTimer := TTimer.Create(Self);
  FGoodsSearchTimer.Interval := 350;
  FGoodsSearchTimer.Enabled := False;
  FGoodsSearchTimer.OnTimer := SearchTimerTimer;

  // --- Панель кнопок внизу ---
  Panel := TPanel.Create(Self);
  Panel.Parent := FTabGoods;
  Panel.Align := TAlignLayout.Bottom;
  Panel.Height := 100;

  FGoodsAddBtn := TButton.Create(Self);
  FGoodsAddBtn.Parent := Panel;
  FGoodsAddBtn.Position.X := 10;
  FGoodsAddBtn.Position.Y := 10;
  FGoodsAddBtn.Width := 120;
  FGoodsAddBtn.Text := '+ Добавить';
  FGoodsAddBtn.OnClick := GoodsAddClick;

  FGoodsEditBtn := TButton.Create(Self);
  FGoodsEditBtn.Parent := Panel;
  FGoodsEditBtn.Position.X := 140;
  FGoodsEditBtn.Position.Y := 10;
  FGoodsEditBtn.Width := 120;
  FGoodsEditBtn.Text := 'Изменить';
  FGoodsEditBtn.OnClick := GoodsEditClick;

  FGoodsDelBtn := TButton.Create(Self);
  FGoodsDelBtn.Parent := Panel;
  FGoodsDelBtn.Position.X := 270;
  FGoodsDelBtn.Position.Y := 10;
  FGoodsDelBtn.Width := 120;
  FGoodsDelBtn.Text := '- Удалить';
  FGoodsDelBtn.OnClick := GoodsDeleteClick;

  FGoodsStatus := TText.Create(Self);
  FGoodsStatus.Parent := Panel;
  FGoodsStatus.Position.X := 10;
  FGoodsStatus.Position.Y := 60;
  FGoodsStatus.Width := 600;
  FGoodsStatus.Text := 'Справочник товаров';

  // Грид создаётся ПОСЛЕДНИМ: в FMX порядок Align рассчитывается по
  // порядку создания, и Client должен получить площадь, оставшуюся после
  // верхней панели поиска и нижней панели кнопок.
  FGoodsGrid := TGrid.Create(Self);
  FGoodsGrid.Parent := FTabGoods;
  FGoodsGrid.Align := TAlignLayout.Client;
  FGoodsGrid.OnHeaderClick := GoodsHeaderClick;
end;

procedure TFormMain.CreateGoodsColumns;
begin
  FGoodsBindings := TBindingsList.Create(Self);
  FGoodsBindSource := TBindSourceDB.Create(Self);
  FGoodsLink := TLinkGridToDataSource.Create(Self);
  FGoodsLink.GridControl := FGoodsGrid;
  FGoodsLink.DataSource := FGoodsBindSource;

  with FGoodsLink.Columns.Add do
  begin
    MemberName := 'GoodsId';
    Header     := 'ID';
    Width      := 50;
  end;
  with FGoodsLink.Columns.Add do
  begin
    MemberName := 'GoodsName';
    Header     := 'Название';
    Width      := 300;
  end;
end;

procedure TFormMain.LoadGoods;
var
  N: Integer;
begin
  try
    N := FGoodsSearch.Text.Trim.Length;
    FGoodsBindSource.DataSet := DM.OpenGoods(FGoodsSort, FGoodsSearch.Text);
    FGoodsStatus.Text := Format('Товаров: %d%s%s',
      [FGoodsBindSource.Dataset.RecordCount,
       IfThen(N > 0, ' (фильтр «' + FGoodsSearch.Text.Trim + '»)', ''),
       ' ' + SortCaption(FGoodsLink, FGoodsSort)]);
  except
    on E: Exception do
      FGoodsStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.GoodsAddClick(Sender: TObject);
var
  Values: TArray<string>;
  NewId: Integer;
begin
  // TDialogServiceSync.InputQuery: промпты и значения передаются массивами,
  // введённые значения возвращаются в том же массиве Values.
  // Синхронный вариант удобен тем, что вставлять можно прямо здесь,
  // без callback-процедуры, как в TDialogService (асинхронный режим по умолчанию).
  SetLength(Values, 1);
  Values[0] := '';
  if not TDialogServiceSync.InputQuery('Добавить товар', ['Название товара'], Values) then
    Exit;                       // нажато «Отмена»
  if Values[0].Trim = '' then
    Exit;
  try
    NewId := DM.GoodsAdd(Values[0].Trim);
    LoadGoods;
    FGoodsStatus.Text := 'Добавлен товар ID=' + IntToStr(NewId);
  except
    on E: Exception do
      FGoodsStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.GoodsEditClick(Sender: TObject);
var
  Values: TArray<string>;
  Id: Integer;
begin
  if FGoodsGrid.Selected < 0 then
  begin
    FGoodsStatus.Text := 'Выберите строку для изменения';
    Exit;
  end;
  // Колонка 0 — GoodsId, колонка 1 — GoodsName (см. CreateGoodsColumns).
  // Текущее название подставляем в диалог, чтобы править, а не вводить заново.
  Id := FGoodsGrid.Model.GetValue(0, FGoodsGrid.Selected, False).AsInteger;
  SetLength(Values, 1);
  Values[0] := FGoodsGrid.Model.GetValue(1, FGoodsGrid.Selected, False).ToString;
  if not TDialogServiceSync.InputQuery('Изменить товар ID=' + IntToStr(Id),
       ['Название товара'], Values) then
    Exit;
  if Values[0].Trim = '' then
    Exit;
  try
    DM.GoodsUpdate(Id, Values[0].Trim);
    LoadGoods;
    // Справочник изменился — комбобоксы вкладок читают его же курсор.
    FillIncomeCombos;
    FillOutcomeCombo;
    FillTransferCombos;
    FGoodsStatus.Text := 'Изменён товар ID=' + IntToStr(Id);
  except
    on E: Exception do
      FGoodsStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.GoodsDeleteClick(Sender: TObject);
var
  Id: Integer;
  Result: Integer;
begin
  if FGoodsGrid.Selected < 0 then
  begin
    FGoodsStatus.Text := 'Выберите строку для удаления';
    Exit;
  end;
  Id := FGoodsGrid.Model.GetValue(0, FGoodsGrid.Selected, False).AsInteger;
  Result := TDialogServiceSync.MessageDialog(
    'Удалить товар ID=' + IntToStr(Id) + '?',
    TMsgDlgType.mtConfirmation, mbYesNo, TMsgDlgBtn.mbNo, 0);
  if Result <> mrYes then Exit;
  try
    DM.GoodsDelete(Id);
    LoadGoods;
    FGoodsStatus.Text := 'Удалён товар ID=' + IntToStr(Id);
  except
    on E: Exception do
      FGoodsStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// ============================================================================
// Вкладка "Склады"
// ============================================================================

procedure TFormMain.CreateWarehousesControls;
var
  Panel, SearchPanel: TPanel;
  SearchLabel: TText;
begin
  Panel := TPanel.Create(Self);
  Panel.Parent := FTabWarehouses;
  Panel.Align := TAlignLayout.Bottom;
  Panel.Height := 100;

  FWarehousesAddBtn := TButton.Create(Self);
  FWarehousesAddBtn.Parent := Panel;
  FWarehousesAddBtn.Position.X := 10;
  FWarehousesAddBtn.Position.Y := 10;
  FWarehousesAddBtn.Width := 120;
  FWarehousesAddBtn.Text := '+ Добавить';
  FWarehousesAddBtn.OnClick := WarehousesAddClick;

  FWarehousesEditBtn := TButton.Create(Self);
  FWarehousesEditBtn.Parent := Panel;
  FWarehousesEditBtn.Position.X := 140;
  FWarehousesEditBtn.Position.Y := 10;
  FWarehousesEditBtn.Width := 120;
  FWarehousesEditBtn.Text := 'Изменить';
  FWarehousesEditBtn.OnClick := WarehousesEditClick;

  FWarehousesDelBtn := TButton.Create(Self);
  FWarehousesDelBtn.Parent := Panel;
  FWarehousesDelBtn.Position.X := 270;
  FWarehousesDelBtn.Position.Y := 10;
  FWarehousesDelBtn.Width := 120;
  FWarehousesDelBtn.Text := '- Удалить';
  FWarehousesDelBtn.OnClick := WarehousesDeleteClick;

  FWarehousesStatus := TText.Create(Self);
  FWarehousesStatus.Parent := Panel;
  FWarehousesStatus.Position.X := 10;
  FWarehousesStatus.Position.Y := 60;
  FWarehousesStatus.Width := 600;
  FWarehousesStatus.Text := 'Справочник складов';

  // Панель поиска (создаётся после нижней, но Align=Top возьмёт верх
  // оставшейся площади; грид — последним, см. комментарий в CreateGoodsControls).
  SearchPanel := TPanel.Create(Self);
  SearchPanel.Parent := FTabWarehouses;
  SearchPanel.Align := TAlignLayout.Top;
  SearchPanel.Height := 40;

  SearchLabel := TText.Create(Self);
  SearchLabel.Parent := SearchPanel;
  SearchLabel.Position.X := 10;
  SearchLabel.Position.Y := 10;
  SearchLabel.Width := 40;
  SearchLabel.Height := 20;
  SearchLabel.Text := 'Поиск:';
  SearchLabel.VertTextAlign := TTextAlign.Leading;

  FWarehousesSearch := TEdit.Create(Self);
  FWarehousesSearch.Parent := SearchPanel;
  FWarehousesSearch.Position.X := 55;
  FWarehousesSearch.Position.Y := 8;
  FWarehousesSearch.Width := 250;
  FWarehousesSearch.TextPrompt := 'Введите текст и подождите...';
  FWarehousesSearch.OnChange := WarehousesSearchChange;

  FWarehousesSearchTimer := TTimer.Create(Self);
  FWarehousesSearchTimer.Interval := 350;
  FWarehousesSearchTimer.Enabled := False;
  FWarehousesSearchTimer.OnTimer := SearchTimerTimer;

  FWarehousesGrid := TGrid.Create(Self);
  FWarehousesGrid.Parent := FTabWarehouses;
  FWarehousesGrid.Align := TAlignLayout.Client;
  FWarehousesGrid.OnHeaderClick := WarehousesHeaderClick;
end;

procedure TFormMain.CreateWarehousesColumns;
begin
  FWarehousesBindings := TBindingsList.Create(Self);
  FWarehousesBindSource := TBindSourceDB.Create(Self);
  FWarehousesLink := TLinkGridToDataSource.Create(Self);
  FWarehousesLink.GridControl := FWarehousesGrid;
  FWarehousesLink.DataSource := FWarehousesBindSource;

  with FWarehousesLink.Columns.Add do
  begin
    MemberName := 'WarehouseId';
    Header     := 'ID';
    Width      := 50;
  end;
  with FWarehousesLink.Columns.Add do
  begin
    MemberName := 'WarehouseName';
    Header     := 'Название';
    Width      := 300;
  end;
end;

procedure TFormMain.LoadWarehouses;
var
  N: Integer;
begin
  try
    N := FWarehousesSearch.Text.Trim.Length;
    FWarehousesBindSource.DataSet := DM.OpenWarehouses(FWarehousesSort,
      FWarehousesSearch.Text);
    FWarehousesStatus.Text := Format('Складов: %d%s%s',
      [FWarehousesBindSource.Dataset.RecordCount,
       IfThen(N > 0, ' (фильтр «' + FWarehousesSearch.Text.Trim + '»)', ''),
       ' ' + SortCaption(FWarehousesLink, FWarehousesSort)]);
  except
    on E: Exception do
      FWarehousesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.WarehousesAddClick(Sender: TObject);
var
  Values: TArray<string>;
  NewId: Integer;
begin
  SetLength(Values, 1);
  Values[0] := '';
  if not TDialogServiceSync.InputQuery('Добавить склад', ['Название склада'], Values) then
    Exit;
  if Values[0].Trim = '' then
    Exit;
  try
    NewId := DM.WarehouseAdd(Values[0].Trim);
    LoadWarehouses;
    FWarehousesStatus.Text := 'Добавлен склад ID=' + IntToStr(NewId);
  except
    on E: Exception do
      FWarehousesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.WarehousesEditClick(Sender: TObject);
var
  Values: TArray<string>;
  Id: Integer;
begin
  if FWarehousesGrid.Selected < 0 then
  begin
    FWarehousesStatus.Text := 'Выберите строку для изменения';
    Exit;
  end;
  Id := FWarehousesGrid.Model.GetValue(0, FWarehousesGrid.Selected, False).AsInteger;
  SetLength(Values, 1);
  Values[0] := FWarehousesGrid.Model.GetValue(1, FWarehousesGrid.Selected, False).ToString;
  if not TDialogServiceSync.InputQuery('Изменить склад ID=' + IntToStr(Id),
       ['Название склада'], Values) then
    Exit;
  if Values[0].Trim = '' then
    Exit;
  try
    DM.WarehouseUpdate(Id, Values[0].Trim);
    LoadWarehouses;
    FillIncomeCombos;   // список складов на вкладке «Приход» тоже обновить
    FWarehousesStatus.Text := 'Изменён склад ID=' + IntToStr(Id);
  except
    on E: Exception do
      FWarehousesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.WarehousesDeleteClick(Sender: TObject);
var
  Id: Integer;
begin
  if FWarehousesGrid.Selected < 0 then
  begin
    FWarehousesStatus.Text := 'Выберите строку для удаления';
    Exit;
  end;
  Id := FWarehousesGrid.Model.GetValue(0, FWarehousesGrid.Selected, False).AsInteger;
  if TDialogServiceSync.MessageDialog(
    'Удалить склад ID=' + IntToStr(Id) + '?',
    TMsgDlgType.mtConfirmation, mbYesNo, TMsgDlgBtn.mbNo, 0) <> mrYes then Exit;
  try
    DM.WarehouseDelete(Id);
    LoadWarehouses;
    FWarehousesStatus.Text := 'Удалён склад ID=' + IntToStr(Id);
  except
    on E: Exception do
      FWarehousesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// ============================================================================
// Вкладка "Места"
// ============================================================================

procedure TFormMain.CreatePlacesControls;
var
  Panel, SearchPanel: TPanel;
  SearchLabel: TText;
begin
  Panel := TPanel.Create(Self);
  Panel.Parent := FTabPlaces;
  Panel.Align := TAlignLayout.Bottom;
  Panel.Height := 100;

  FPlacesAddBtn := TButton.Create(Self);
  FPlacesAddBtn.Parent := Panel;
  FPlacesAddBtn.Position.X := 10;
  FPlacesAddBtn.Position.Y := 10;
  FPlacesAddBtn.Width := 120;
  FPlacesAddBtn.Text := '+ Добавить';
  FPlacesAddBtn.OnClick := PlacesAddClick;

  FPlacesEditBtn := TButton.Create(Self);
  FPlacesEditBtn.Parent := Panel;
  FPlacesEditBtn.Position.X := 140;
  FPlacesEditBtn.Position.Y := 10;
  FPlacesEditBtn.Width := 120;
  FPlacesEditBtn.Text := 'Изменить';
  FPlacesEditBtn.OnClick := PlacesEditClick;

  FPlacesDelBtn := TButton.Create(Self);
  FPlacesDelBtn.Parent := Panel;
  FPlacesDelBtn.Position.X := 270;
  FPlacesDelBtn.Position.Y := 10;
  FPlacesDelBtn.Width := 120;
  FPlacesDelBtn.Text := '- Удалить';
  FPlacesDelBtn.OnClick := PlacesDeleteClick;

  FPlacesStatus := TText.Create(Self);
  FPlacesStatus.Parent := Panel;
  FPlacesStatus.Position.X := 10;
  FPlacesStatus.Position.Y := 60;
  FPlacesStatus.Width := 600;
  FPlacesStatus.Text := 'Справочник мест';

  SearchPanel := TPanel.Create(Self);
  SearchPanel.Parent := FTabPlaces;
  SearchPanel.Align := TAlignLayout.Top;
  SearchPanel.Height := 40;

  SearchLabel := TText.Create(Self);
  SearchLabel.Parent := SearchPanel;
  SearchLabel.Position.X := 10;
  SearchLabel.Position.Y := 10;
  SearchLabel.Width := 40;
  SearchLabel.Height := 20;
  SearchLabel.Text := 'Поиск:';
  SearchLabel.VertTextAlign := TTextAlign.Leading;

  FPlacesSearch := TEdit.Create(Self);
  FPlacesSearch.Parent := SearchPanel;
  FPlacesSearch.Position.X := 55;
  FPlacesSearch.Position.Y := 8;
  FPlacesSearch.Width := 250;
  FPlacesSearch.TextPrompt := 'Место или склад...';
  FPlacesSearch.OnChange := PlacesSearchChange;

  FPlacesSearchTimer := TTimer.Create(Self);
  FPlacesSearchTimer.Interval := 350;
  FPlacesSearchTimer.Enabled := False;
  FPlacesSearchTimer.OnTimer := SearchTimerTimer;

  FPlacesGrid := TGrid.Create(Self);
  FPlacesGrid.Parent := FTabPlaces;
  FPlacesGrid.Align := TAlignLayout.Client;
  FPlacesGrid.OnHeaderClick := PlacesHeaderClick;
end;

procedure TFormMain.CreatePlacesColumns;
begin
  FPlacesBindings := TBindingsList.Create(Self);
  FPlacesBindSource := TBindSourceDB.Create(Self);
  FPlacesLink := TLinkGridToDataSource.Create(Self);
  FPlacesLink.GridControl := FPlacesGrid;
  FPlacesLink.DataSource := FPlacesBindSource;

  with FPlacesLink.Columns.Add do
  begin
    MemberName := 'PlaceId';
    Header     := 'ID';
    Width      := 50;
  end;
  with FPlacesLink.Columns.Add do
  begin
    MemberName := 'PlaceName';
    Header     := 'Название';
    Width      := 100;
  end;
  with FPlacesLink.Columns.Add do
  begin
    MemberName := 'WarehouseName';
    Header     := 'Склад';
    Width      := 200;
  end;
end;

procedure TFormMain.LoadPlaces;
var
  N: Integer;
begin
  try
    N := FPlacesSearch.Text.Trim.Length;
    FPlacesBindSource.DataSet := DM.OpenPlaces(FPlacesSort, FPlacesSearch.Text);
    FPlacesStatus.Text := Format('Мест: %d%s%s',
      [FPlacesBindSource.Dataset.RecordCount,
       IfThen(N > 0, ' (фильтр «' + FPlacesSearch.Text.Trim + '»)', ''),
       ' ' + SortCaption(FPlacesLink, FPlacesSort)]);
  except
    on E: Exception do
      FPlacesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.PlacesAddClick(Sender: TObject);
var
  Values: TArray<string>;
  WId: Integer;
  NewId: Integer;
begin
  // Два поля в одном диалоге: название места и ID склада.
  SetLength(Values, 2);
  Values[0] := '';
  Values[1] := '1';
  if not TDialogServiceSync.InputQuery('Добавить место',
       ['Название места (например А-1-3)', 'ID склада'], Values) then
    Exit;
  if Values[0].Trim = '' then
    Exit;
  WId := StrToIntDef(Values[1].Trim, 0);
  if WId <= 0 then
  begin
    FPlacesStatus.Text := 'Некорректный ID склада';
    Exit;
  end;
  try
    NewId := DM.PlaceAdd(WId, Values[0].Trim);
    LoadPlaces;
    FPlacesStatus.Text := 'Добавлено место ID=' + IntToStr(NewId);
  except
    on E: Exception do
      FPlacesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.PlacesEditClick(Sender: TObject);
var
  Values: TArray<string>;
  Id, CurWh: Integer;
  DS: TDataSet;
begin
  if FPlacesGrid.Selected < 0 then
  begin
    FPlacesStatus.Text := 'Выберите строку для изменения';
    Exit;
  end;
  Id := FPlacesGrid.Model.GetValue(0, FPlacesGrid.Selected, False).AsInteger;

  // Текущий склад строки берём из курсора: в гриде только название склада,
  // а в UPDATE нужен WarehouseId.
  CurWh := 0;
  DS := DM.PlacesDataSet;
  if DS.Active then
  begin
    DS.DisableControls;
    try
      DS.First;
      while not DS.Eof do
      begin
        if DS.FieldByName('PlaceId').AsInteger = Id then
        begin
          CurWh := DS.FieldByName('WarehouseId').AsInteger;
          Break;
        end;
        DS.Next;
      end;
      DS.First;
    finally
      DS.EnableControls;
    end;
  end;

  SetLength(Values, 2);
  Values[0] := FPlacesGrid.Model.GetValue(1, FPlacesGrid.Selected, False).ToString;
  Values[1] := IntToStr(CurWh);
  if not TDialogServiceSync.InputQuery('Изменить место ID=' + IntToStr(Id),
       ['Название места', 'ID склада'], Values) then
    Exit;
  if Values[0].Trim = '' then
    Exit;
  if StrToIntDef(Values[1].Trim, 0) <= 0 then
  begin
    FPlacesStatus.Text := 'Некорректный ID склада';
    Exit;
  end;
  try
    DM.PlaceUpdate(Id, StrToInt(Values[1].Trim), Values[0].Trim);
    LoadPlaces;
    FillIncomeCombos;   // список мест на вкладке «Приход» тоже обновить
    FillTransferCombos;
    FPlacesStatus.Text := 'Изменено место ID=' + IntToStr(Id);
  except
    on E: Exception do
      FPlacesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.PlacesDeleteClick(Sender: TObject);
var
  Id: Integer;
begin
  if FPlacesGrid.Selected < 0 then
  begin
    FPlacesStatus.Text := 'Выберите строку для удаления';
    Exit;
  end;
  Id := FPlacesGrid.Model.GetValue(0, FPlacesGrid.Selected, False).AsInteger;
  if TDialogServiceSync.MessageDialog(
    'Удалить место ID=' + IntToStr(Id) + '?',
    TMsgDlgType.mtConfirmation, mbYesNo, TMsgDlgBtn.mbNo, 0) <> mrYes then Exit;
  try
    DM.PlaceDelete(Id);
    LoadPlaces;
    FPlacesStatus.Text := 'Удалено место ID=' + IntToStr(Id);
  except
    on E: Exception do
      FPlacesStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// ============================================================================
// Вкладка "Приход" — форма ввода приходного документа (SPECIFICATION.md II.2.3)
//
//   [Товар ▼]   [Склад ▼]   [Место ▼]
//   [Дата]      [Время]     [Кол-во] [Цена]
//   [Срок]      [x] Без срока
//   [Комментарий]              [Оформить приход]
//
// Источник данных комбобоксов — те же открытые курсоры, что у гридов
// справочников (DM.GoodsDataSet / WarehousesDataSet / PlacesDataSet).
// Без MARS на соединении живёт один активный серверный курсор, поэтому
// отдельный lookup-запрос открывать нельзя: списки читаются из уже
// открытых курсоров, а курсор после чтения возвращается в начало.
// ============================================================================

procedure TFormMain.CreateIncomeControls;

  // Метка поля. Владелец — форма (Self), поэтому метка будет освобождена
  // вместе с ней: TControl.Create(AOwner) и .Parent — разные вещи, без
  // явного владельца компонент висел бы в воздухе и протекал.
  // Height := 20 обязателен: у TText значение по умолчанию ~100, и метка
  // визуально «проваливалась» под своё поле.
  function MakeLabel(const ACaption: string; AX, AY, AW: Single): TText;
  begin
    Result := TText.Create(Self);
    Result.Parent := FIncomePanel;
    Result.Text := ACaption;
    Result.Position.X := AX;
    Result.Position.Y := AY;
    Result.Width := AW;
    Result.Height := 20;
    Result.VertTextAlign := TTextAlign.Leading;
  end;

var
  Y1, Y2, Y3, Y4: Single;
begin
  FIncomePanel := TPanel.Create(Self);
  FIncomePanel.Parent := FTabIncome;
  FIncomePanel.Align := TAlignLayout.Top;
  FIncomePanel.Height := 230;

  Y1 := 12;   // ряд комбобоксов
  Y2 := 54;   // дата / время / количество / цена
  Y3 := 96;   // срок + чекбокс
  Y4 := 138;  // комментарий

  // --- Ряд 1: Товар / Склад / Место ---
  MakeLabel('Товар', 10, Y1 + 5, 50);
  FIncomeGoodsCb := TComboBox.Create(Self);
  FIncomeGoodsCb.Parent := FIncomePanel;
  FIncomeGoodsCb.Position.X := 65;
  FIncomeGoodsCb.Position.Y := Y1;
  FIncomeGoodsCb.Width := 180;

  MakeLabel('Склад', 260, Y1 + 5, 50);
  FIncomeWhCb := TComboBox.Create(Self);
  FIncomeWhCb.Parent := FIncomePanel;
  FIncomeWhCb.Position.X := 315;
  FIncomeWhCb.Position.Y := Y1;
  FIncomeWhCb.Width := 180;
  // Смена склада меняет список мест: места привязаны к складу.
  FIncomeWhCb.OnChange := IncomeWhCbChange;

  MakeLabel('Место', 510, Y1 + 5, 50);
  FIncomePlaceCb := TComboBox.Create(Self);
  FIncomePlaceCb.Parent := FIncomePanel;
  FIncomePlaceCb.Position.X := 565;
  FIncomePlaceCb.Position.Y := Y1;
  FIncomePlaceCb.Width := 180;

  // --- Ряд 2: Дата / Время / Кол-во / Цена ---
  MakeLabel('Дата', 10, Y2 + 5, 40);
  FIncomeDate := TDateEdit.Create(Self);
  FIncomeDate.Parent := FIncomePanel;
  FIncomeDate.Position.X := 55;
  FIncomeDate.Position.Y := Y2;
  FIncomeDate.Width := 120;
  FIncomeDate.Date := Now;

  MakeLabel('Время', 190, Y2 + 5, 45);
  FIncomeTime := TTimeEdit.Create(Self);
  FIncomeTime.Parent := FIncomePanel;
  FIncomeTime.Position.X := 240;
  FIncomeTime.Position.Y := Y2;
  FIncomeTime.Width := 110;
  FIncomeTime.UseNowTime := True;

  MakeLabel('Кол-во', 365, Y2 + 5, 45);
  FIncomeQty := TEdit.Create(Self);
  FIncomeQty.Parent := FIncomePanel;
  FIncomeQty.Position.X := 415;
  FIncomeQty.Position.Y := Y2;
  FIncomeQty.Width := 90;
  FIncomeQty.Text := '1';

  MakeLabel('Цена', 520, Y2 + 5, 35);
  FIncomePrice := TEdit.Create(Self);
  FIncomePrice.Parent := FIncomePanel;
  FIncomePrice.Position.X := 560;
  FIncomePrice.Position.Y := Y2;
  FIncomePrice.Width := 90;
  FIncomePrice.Text := '0';

  // --- Ряд 3: Срок годности + «Без срока» ---
  MakeLabel('Срок', 10, Y3 + 5, 40);
  FIncomeExpiry := TDateEdit.Create(Self);
  FIncomeExpiry.Parent := FIncomePanel;
  FIncomeExpiry.Position.X := 55;
  FIncomeExpiry.Position.Y := Y3;
  FIncomeExpiry.Width := 120;

  FIncomeNoExpiry := TCheckBox.Create(Self);
  FIncomeNoExpiry.Parent := FIncomePanel;
  FIncomeNoExpiry.Position.X := 190;
  FIncomeNoExpiry.Position.Y := Y3 + 3;
  FIncomeNoExpiry.Text := 'Без срока';
  // По умолчанию срок не задан: большинство позиций приходуются без него,
  // а поле ExpiryDate в БД допускает NULL.
  FIncomeNoExpiry.IsChecked := True;
  // OnChange, а не OnClick: у FMX-чекбокса OnClick срабатывает ДО смены
  // IsChecked — обработчик читал старое значение и блокировка поля
  // «ехала» на клик назад (инвертировалась).
  FIncomeNoExpiry.OnChange := IncomeNoExpiryChange;
  FIncomeExpiry.Enabled := False;

  // --- Ряд 4: Комментарий + кнопка ---
  MakeLabel('Комментарий', 10, Y4 + 5, 80);
  FIncomeComment := TEdit.Create(Self);
  FIncomeComment.Parent := FIncomePanel;
  FIncomeComment.Position.X := 95;
  FIncomeComment.Position.Y := Y4;
  FIncomeComment.Width := 400;

  FIncomeAddBtn := TButton.Create(Self);
  FIncomeAddBtn.Parent := FIncomePanel;
  FIncomeAddBtn.Position.X := 510;
  FIncomeAddBtn.Position.Y := Y4;
  FIncomeAddBtn.Width := 160;
  FIncomeAddBtn.Text := 'Оформить приход';
  FIncomeAddBtn.OnClick := IncomeAddClick;

  // --- Статус ---
  FIncomeStatus := TText.Create(Self);
  FIncomeStatus.Parent := FTabIncome;
  FIncomeStatus.Align := TAlignLayout.Bottom;
  FIncomeStatus.Height := 30;
  FIncomeStatus.Text := 'Заполните поля и нажмите «Оформить приход»';
  // Комбобоксы заполняет конструктор ПОСЛЕ Load* — здесь курсоры ещё закрыты.
end;

procedure TFormMain.IncomeWhCbChange(Sender: TObject);
begin
  ApplyPlaceFilter;
end;

procedure TFormMain.IncomeNoExpiryChange(Sender: TObject);
begin
  FIncomeExpiry.Enabled := not FIncomeNoExpiry.IsChecked;
  if FIncomeExpiry.Enabled then
    FIncomeExpiry.SetFocus;
end;

// Заполняет список мест из уже открытого курсора мест, оставляя только
// выбранного склада. Курсор возвращаем в начало и глушим уведомления
// (DisableControls), иначе грид вкладки «Места» прокрутился бы за курсором.
procedure TFormMain.ApplyPlaceFilter;
var
  DS: TDataSet;
  SelWh, Id: Int64;
  Idx: Integer;
begin
  FIncomePlaceCb.Items.Clear;
  FPlaceIds := [];
  if FIncomeWhCb.ItemIndex < 0 then Exit;
  if FIncomeWhCb.ItemIndex >= Length(FWhIds) then Exit;
  SelWh := FWhIds[FIncomeWhCb.ItemIndex];

  DS := DM.PlacesDataSet;
  if not DS.Active then Exit;
  DS.DisableControls;
  try
    DS.First;
    while not DS.Eof do
    begin
      if DS.FieldByName('WarehouseId').AsLargeInt = SelWh then
      begin
        Id := DS.FieldByName('PlaceId').AsLargeInt;
        FIncomePlaceCb.Items.Add(DS.FieldByName('PlaceName').AsString);
        Idx := Length(FPlaceIds);
        SetLength(FPlaceIds, Idx + 1);
        FPlaceIds[Idx] := Id;
      end;
      DS.Next;
    end;
    DS.First;
  finally
    DS.EnableControls;
  end;

  if Length(FPlaceIds) > 0 then
    FIncomePlaceCb.ItemIndex := 0
  else
    FIncomePlaceCb.ItemIndex := -1;
end;

// Наполняет комбобоксы товаров и складов из открытых курсоров справочников.
// Параллельно собирает массивы ключей: TComboBox хранит только отображаемый
// текст, а в запрос должны уходить GoodsId / WarehouseId строки под текстом.
procedure TFormMain.FillIncomeCombos;

  procedure FillFrom(DS: TDataSet; Cb: TComboBox; var Ids: TArray<Int64>;
    const AIdField, ANameField: string);
  var
    Idx: Integer;
  begin
    Cb.Items.BeginUpdate;
    try
      Cb.Items.Clear;
      Ids := [];
      if not DS.Active then Exit;
      DS.DisableControls;
      try
        DS.First;
        while not DS.Eof do
        begin
          Cb.Items.Add(DS.FieldByName(ANameField).AsString);
          Idx := Length(Ids);
          SetLength(Ids, Idx + 1);
          Ids[Idx] := DS.FieldByName(AIdField).AsLargeInt;
          DS.Next;
        end;
        DS.First;
      finally
        DS.EnableControls;
      end;
    finally
      Cb.Items.EndUpdate;
    end;
    if Length(Ids) > 0 then
      Cb.ItemIndex := 0
    else
      Cb.ItemIndex := -1;
  end;

begin
  FillFrom(DM.GoodsDataSet, FIncomeGoodsCb, FGoodsIds, 'GoodsId', 'GoodsName');
  FillFrom(DM.WarehousesDataSet, FIncomeWhCb, FWhIds,
    'WarehouseId', 'WarehouseName');
  ApplyPlaceFilter;
end;

procedure TFormMain.IncomeAddClick(Sender: TObject);
var
  Qty, Price: Double;
  DocDate, ExpiryDate: TDateTime;
  DocId: Integer;
begin
  if (FIncomeGoodsCb.ItemIndex < 0) or (Length(FGoodsIds) = 0) then
  begin
    FIncomeStatus.Text := 'Выберите товар';
    Exit;
  end;
  if (FIncomePlaceCb.ItemIndex < 0) or (Length(FPlaceIds) = 0) then
  begin
    FIncomeStatus.Text := 'Выберите место (на складе должны быть места)';
    Exit;
  end;
  if not ParseNum(FIncomeQty.Text, Qty) or (Qty <= 0) then
  begin
    FIncomeStatus.Text := 'Количество должно быть числом больше нуля';
    Exit;
  end;
  if not ParseNum(FIncomePrice.Text, Price) or (Price < 0) then
  begin
    FIncomeStatus.Text := 'Цена должна быть числом не меньше нуля';
    Exit;
  end;

  // TTimeEdit.Time — дробная часть суток; в сумме с датой даёт момент
  // документа. Он уходит и в Batch.IncomeDate (ключ FIFO), и в
  // StockMovement.MovementDate — см. комментарий в TDM.DocumentIncome.
  DocDate := FIncomeDate.Date + FIncomeTime.Time;

  if FIncomeNoExpiry.IsChecked then
    ExpiryDate := 0     // DocumentIncome превратит 0 в NULL
  else
    ExpiryDate := FIncomeExpiry.Date;

  try
    DocId := DM.DocumentIncome(
      FGoodsIds[FIncomeGoodsCb.ItemIndex],
      FPlaceIds[FIncomePlaceCb.ItemIndex],
      Qty, Price, DocDate, ExpiryDate, FIncomeComment.Text);
    FIncomeStatus.Text := Format(
      'Приход №%d: %s, %s, кол-во %s, цена %s',
      [DocId, FIncomeGoodsCb.Text, FIncomePlaceCb.Text,
       FIncomeQty.Text, FIncomePrice.Text]);
    // DocumentIncome переоткрыл курсоры справочников — данные свежена,
    // комбобоксы перечитываем (вдруг список пополнился через CRUD).
    FillIncomeCombos;
  except
    on E: Exception do
      FIncomeStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// ============================================================================
// Общие помощники формы
// ============================================================================

// Количественные поля пользователь вводит руками, поэтому разделитель
// может быть и точкой, и запятой. Приводим запятую к точке и разбираем
// с явными TFormatSettings — иначе разбор зависит от локали Windows.
function TFormMain.ParseNum(const S: string; out V: Double): Boolean;
var
  FS: TFormatSettings;
begin
  FS := TFormatSettings.Create;
  FS.DecimalSeparator := '.';
  // Char(160) — неразрывный пробел: он не встречается во вводе пользователя,
  // поэтому «1 000» не будет ошибочно прочитано как «1000» с группировкой.
  FS.ThousandSeparator := Char(160);
  Result := TryStrToFloat(StringReplace(S, ',', '.', [rfReplaceAll]), V, FS);
end;

// Подпись поля над элементом ввода. В FMX у TText значение Height по
// умолчанию ~100, и наложение подписи на поле выглядело как «метка под
// полем». Фиксируем маленькую высоту и выравнивание сверху.
function TFormMain.MakeLabel(const ACaption: string; AX, AY, AW: Single;
  AParent: TPanel): TText;
begin
  Result := TText.Create(Self);
  Result.Parent := AParent;
  Result.Text := ACaption;
  Result.Position.X := AX;
  Result.Position.Y := AY;
  Result.Width := AW;
  Result.Height := 20;
  Result.Align := TAlignLayout.None;
  Result.VertTextAlign := TTextAlign.Leading;
end;

// ============================================================================
// Вкладка "Расход" — упрощённая форма (Вариант B)
//
//   [Товар ▼]  [Остаток: N шт]  [Кол-во]
//   [Дата]     [Время]          [Комментарий]
//   [ ] Вручную  [Партия № ______]  [Списать]
//
// Перед списанием — диалог подтверждения с расчётом (DM.PeekOutcome*).
// ============================================================================

procedure TFormMain.CreateOutcomeControls;
var
  Y: Single;
begin
  FOutPanel := TPanel.Create(Self);
  FOutPanel.Parent := FTabOutcome;
  FOutPanel.Align := TAlignLayout.Top;
  FOutPanel.Height := 160;

  Y := 12;

  // --- Строка 1: Товар, Остаток, Кол-во ---
  MakeLabel('Товар', 10, Y + 5, 50, FOutPanel);
  FOutGoodsCb := TComboBox.Create(Self);
  FOutGoodsCb.Parent := FOutPanel;
  FOutGoodsCb.Position.X := 65;
  FOutGoodsCb.Position.Y := Y;
  FOutGoodsCb.Width := 200;
  FOutGoodsCb.OnChange := OutcomeGoodsCbChange;

  FOutLeft := TText.Create(Self);
  FOutLeft.Parent := FOutPanel;
  FOutLeft.Position.X := 280;
  FOutLeft.Position.Y := Y + 5;
  FOutLeft.Width := 200;
  FOutLeft.Height := 20;
  FOutLeft.Align := TAlignLayout.None;
  FOutLeft.VertTextAlign := TTextAlign.Leading;
  FOutLeft.Text := 'Остаток: —';

  MakeLabel('Кол-во', 500, Y + 5, 45, FOutPanel);
  FOutQty := TEdit.Create(Self);
  FOutQty.Parent := FOutPanel;
  FOutQty.Position.X := 550;
  FOutQty.Position.Y := Y;
  FOutQty.Width := 90;
  FOutQty.Text := '1';

  // --- Строка 2: Дата, Время, Комментарий ---
  Y := 54;
  MakeLabel('Дата', 10, Y + 5, 40, FOutPanel);
  FOutDate := TDateEdit.Create(Self);
  FOutDate.Parent := FOutPanel;
  FOutDate.Position.X := 55;
  FOutDate.Position.Y := Y;
  FOutDate.Width := 120;
  FOutDate.Date := Now;

  MakeLabel('Время', 190, Y + 5, 45, FOutPanel);
  FOutTime := TTimeEdit.Create(Self);
  FOutTime.Parent := FOutPanel;
  FOutTime.Position.X := 240;
  FOutTime.Position.Y := Y;
  FOutTime.Width := 110;
  FOutTime.UseNowTime := True;

  MakeLabel('Комментарий', 365, Y + 5, 80, FOutPanel);
  FOutComment := TEdit.Create(Self);
  FOutComment.Parent := FOutPanel;
  FOutComment.Position.X := 450;
  FOutComment.Position.Y := Y;
  FOutComment.Width := 300;

  // --- Строка 3: Чекбокс "Вручную" + Партия ---
  Y := 96;
  FOutManualCb := TCheckBox.Create(Self);
  FOutManualCb.Parent := FOutPanel;
  FOutManualCb.Position.X := 10;
  FOutManualCb.Position.Y := Y;
  FOutManualCb.Text := 'Вручную';
  FOutManualCb.OnChange := OutcomeManualCbChange;

  FOutBatchNoLabel := TText.Create(Self);
  FOutBatchNoLabel.Parent := FOutPanel;
  FOutBatchNoLabel.Position.X := 120;
  FOutBatchNoLabel.Position.Y := Y + 5;
  FOutBatchNoLabel.Width := 70;
  FOutBatchNoLabel.Height := 20;
  FOutBatchNoLabel.Align := TAlignLayout.None;
  FOutBatchNoLabel.VertTextAlign := TTextAlign.Leading;
  FOutBatchNoLabel.Text := 'Партия №:';

  FOutBatchNo := TEdit.Create(Self);
  FOutBatchNo.Parent := FOutPanel;
  FOutBatchNo.Position.X := 195;
  FOutBatchNo.Position.Y := Y;
  FOutBatchNo.Width := 120;
  FOutBatchNo.Enabled := False;

  // --- Кнопка ---
  FOutAddBtn := TButton.Create(Self);
  FOutAddBtn.Parent := FOutPanel;
  FOutAddBtn.Position.X := 350;
  FOutAddBtn.Position.Y := Y;
  FOutAddBtn.Width := 140;
  FOutAddBtn.Text := 'Списать';
  FOutAddBtn.OnClick := OutcomeAddClick;

  // --- Список партий выбранного товара (только чтение) ---
  // Пользователю было непонятно, откуда диалог берёт партии — теперь
  // список виден сразу под формой: Партия | Склад | Приход | Цена | Остаток.
  FOutBatchGrid := TGrid.Create(Self);
  FOutBatchGrid.Parent := FTabOutcome;
  FOutBatchGrid.Align := TAlignLayout.Client;

  // --- Статус ---
  FOutStatus := TText.Create(Self);
  FOutStatus.Parent := FTabOutcome;
  FOutStatus.Align := TAlignLayout.Bottom;
  FOutStatus.Height := 30;
  FOutStatus.Text := 'Выберите товар — появится остаток и список партий';
  FOutStatus.Align := TAlignLayout.Bottom;
end;

// Колонки списка партий. Read-only: выделять строку не нужно, партию
// выбирает сервер (FIFO) или поле «Партия №» (вручную).
procedure TFormMain.CreateOutcomeBatchColumns;
begin
  FOutBatchBindings := TBindingsList.Create(Self);
  FOutBatchBindSource := TBindSourceDB.Create(Self);
  FOutBatchLink := TLinkGridToDataSource.Create(Self);
  FOutBatchLink.GridControl := FOutBatchGrid;
  FOutBatchLink.DataSource := FOutBatchBindSource;

  with FOutBatchLink.Columns.Add do
  begin
    MemberName := 'BatchId';
    Header     := 'Партия';
    Width      := 70;
  end;
  with FOutBatchLink.Columns.Add do
  begin
    MemberName := 'PlaceName';
    Header     := 'Место';
    Width      := 80;
  end;
  with FOutBatchLink.Columns.Add do
  begin
    MemberName := 'WarehouseName';
    Header     := 'Склад';
    Width      := 130;
  end;
  with FOutBatchLink.Columns.Add do
  begin
    MemberName := 'IncomeDate';
    Header     := 'Приход';
    Width      := 150;
  end;
  with FOutBatchLink.Columns.Add do
  begin
    MemberName    := 'Price';
    Header        := 'Цена';
    Width         := 80;
    DecimalDigits := 2;
  end;
  with FOutBatchLink.Columns.Add do
  begin
    MemberName    := 'QtyLeft';
    Header        := 'Остаток';
    Width         := 90;
    DecimalDigits := 3;
  end;
end;

// Перечитывает партии выбранного товара в грид под формой.
procedure TFormMain.ReloadOutcomeBatches;
var
  DS: TDataSet;
begin
  if (FOutGoodsCb.ItemIndex < 0) or (FOutGoodsCb.ItemIndex >= Length(FOutGoodsIds)) then
  begin
    if FOutBatchBindSource.DataSet <> nil then
      FOutBatchBindSource.DataSet := nil;
    Exit;
  end;
  try
    DS := DM.OpenBatchesForGoods(FOutGoodsIds[FOutGoodsCb.ItemIndex]);
    FOutBatchBindSource.DataSet := DS;
    FOutStatus.Text := Format('Партий с остатком: %d', [DS.RecordCount]);
  except
    on E: Exception do
      FOutStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// Заполняем комбобокс товаров из открытого курсора DM.GoodsDataSet.
procedure TFormMain.FillOutcomeCombo;
var
  DS: TDataSet;
  Idx: Integer;
begin
  DS := DM.GoodsDataSet;
  FOutGoodsCb.Items.BeginUpdate;
  try
    FOutGoodsCb.Items.Clear;
    FOutGoodsIds := [];
    if DS.Active then
    begin
      DS.DisableControls;
      try
        DS.First;
        while not DS.Eof do
        begin
          FOutGoodsCb.Items.Add(DS.FieldByName('GoodsName').AsString);
          Idx := Length(FOutGoodsIds);
          SetLength(FOutGoodsIds, Idx + 1);
          FOutGoodsIds[Idx] := DS.FieldByName('GoodsId').AsLargeInt;
          DS.Next;
        end;
        DS.First;
      finally
        DS.EnableControls;
      end;
    end;
  finally
    FOutGoodsCb.Items.EndUpdate;
  end;
  if Length(FOutGoodsIds) > 0 then
    FOutGoodsCb.ItemIndex := 0
  else
    FOutGoodsCb.ItemIndex := -1;

  // Товар выбран — показать его партии в гриде.
  ReloadOutcomeBatches;
end;

// Смена товара — обновляем остаток и перечитываем список партий.
procedure TFormMain.OutcomeGoodsCbChange(Sender: TObject);
var
  Left: Extended;
begin
  if (FOutGoodsCb.ItemIndex < 0) or (Length(FOutGoodsIds) = 0) then
  begin
    FOutLeft.Text := 'Остаток: —';
    FOutStatus.Text := 'Выберите товар';
    Exit;
  end;
  Left := DM.GoodsTotalLeft(FOutGoodsIds[FOutGoodsCb.ItemIndex]);
  FOutLeft.Text := Format('Остаток: %g шт', [Left]);
  FOutQty.Text := '1';
  ReloadOutcomeBatches;
end;

// Чекбокс "Вручную" — блокирует/разблокирует поле "Партия №".
// OnChange, а не OnClick: OnClick у FMX-чекбокса срабатывает до смены IsChecked.
procedure TFormMain.OutcomeManualCbChange(Sender: TObject);
begin
  FOutBatchNo.Enabled := FOutManualCb.IsChecked;
end;

// Кнопка "Списать" — диалог подтверждения → DocumentOutcome*.
procedure TFormMain.OutcomeAddClick(Sender: TObject);
var
  Qty: Double;
  DocDate: TDateTime;
  PeekText: string;
  BatchId: Int64;
  DocId: Integer;
  Res: TModalResult;
begin
  if (FOutGoodsCb.ItemIndex < 0) or (Length(FOutGoodsIds) = 0) then
  begin
    FOutStatus.Text := 'Выберите товар';
    Exit;
  end;
  if not ParseNum(FOutQty.Text, Qty) or (Qty <= 0) then
  begin
    FOutStatus.Text := 'Количество должно быть числом больше нуля';
    Exit;
  end;

  DocDate := FOutDate.Date + FOutTime.Time;

  try
    if FOutManualCb.IsChecked then
    begin
      // Ручной режим: ищем BatchId по номеру партии.
      if Trim(FOutBatchNo.Text) = '' then
      begin
        FOutStatus.Text := 'Вручную: введите номер партии';
        Exit;
      end;
      // Поле "Партия №" — это BatchId (число).
      if not TryStrToInt64(Trim(FOutBatchNo.Text), BatchId) then
      begin
        FOutStatus.Text := 'Вручную: введите числовой BatchId';
        Exit;
      end;
      // Peek перед подтверждением.
      PeekText := DM.PeekOutcomeManual(BatchId, Qty);
      // Диалог подтверждения.
      Res := TDialogServiceSync.MessageDialog(
        PeekText, TMsgDlgType.mtConfirmation, mbYesNo, TMsgDlgBtn.mbNo, 0);
      if Res = mrYes then
      begin
        DocId := DM.DocumentOutcomeManual(BatchId, Qty, DocDate,
          FOutComment.Text);
        FOutStatus.Text := Format('Расход №%d (вручную, партия %d): %s шт',
          [DocId, BatchId, FOutQty.Text]);
        FOutQty.Text := '1';
        FOutBatchNo.Text := '';
      end
      else
        FOutStatus.Text := 'Отменено пользователем';
    end
    else
    begin
      // FIFO: партии набирает сервер по IncomeDate ASC.
      PeekText := DM.PeekOutcomeFIFO(
        FOutGoodsIds[FOutGoodsCb.ItemIndex],
        0, // все склады
        Qty);
      // Диалог подтверждения.
      Res := TDialogServiceSync.MessageDialog(
        PeekText, TMsgDlgType.mtConfirmation, mbYesNo, TMsgDlgBtn.mbNo, 0);
      if Res = mrYes then
      begin
        DocId := DM.DocumentOutcomeFIFO(
          FOutGoodsIds[FOutGoodsCb.ItemIndex],
          0, // все склады
          Qty, DocDate, FOutComment.Text);
        FOutStatus.Text := Format('Расход №%d (FIFO): %s шт',
          [DocId, FOutQty.Text]);
        FOutQty.Text := '1';
      end
      else
        FOutStatus.Text := 'Отменено пользователем';
    end;
  except
    on E: Exception do
      FOutStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// ============================================================================
// Вкладка "Документы" — реестр (SPECIFICATION.md II.2.2)
//
//   [Тип: Все/Приход/Перемещение/Расход ▼]  [От __] [До __]  [Обновить]
//   ┌────────┬───────────┬────────┬────────────┬────────┬────────┐
//   │ № док  │ Тип       │ Дата   │ Комментарий│ Строк  │ Кол-во │
//   └────────┴───────────┴────────┴────────────┴────────┴────────┘
// ============================================================================

procedure TFormMain.CreateDocsControls;
var
  Y: Single;
begin
  FDocPanel := TPanel.Create(Self);
  FDocPanel.Parent := FTabDocs;
  FDocPanel.Align := TAlignLayout.Top;
  FDocPanel.Height := 110;

  Y := 12;

  MakeLabel('Тип:', 10, Y + 5, 40, FDocPanel);
  FDocTypeCb := TComboBox.Create(Self);
  FDocTypeCb.Parent := FDocPanel;
  FDocTypeCb.Position.X := 60;
  FDocTypeCb.Position.Y := Y;
  FDocTypeCb.Width := 160;
  FDocTypeCb.Items.Add('Все');
  FDocTypeCb.Items.Add('Приход');
  FDocTypeCb.Items.Add('Перемещение');
  FDocTypeCb.Items.Add('Расход');
  FDocTypeCb.ItemIndex := 0;

  MakeLabel('От:', 240, Y + 5, 30, FDocPanel);
  FDocFrom := TDateEdit.Create(Self);
  FDocFrom.Parent := FDocPanel;
  FDocFrom.Position.X := 275;
  FDocFrom.Position.Y := Y;
  FDocFrom.Width := 120;
  FDocFrom.Date := Date;

  MakeLabel('До:', 410, Y + 5, 30, FDocPanel);
  FDocTo := TDateEdit.Create(Self);
  FDocTo.Parent := FDocPanel;
  FDocTo.Position.X := 445;
  FDocTo.Position.Y := Y;
  FDocTo.Width := 120;
  // "До" = начало следующих суток (полунеинтервал [From, To)).
  FDocTo.Date := Date + 1;

  FDocRefreshBtn := TButton.Create(Self);
  FDocRefreshBtn.Parent := FDocPanel;
  FDocRefreshBtn.Position.X := 580;
  FDocRefreshBtn.Position.Y := Y;
  FDocRefreshBtn.Width := 120;
  FDocRefreshBtn.Text := 'Обновить';
  FDocRefreshBtn.OnClick := LoadDocs;

  // --- Второй ряд: поиск по реестру ---
  MakeLabel('Поиск:', 10, 54 + 5, 45, FDocPanel);
  FDocSearch := TEdit.Create(Self);
  FDocSearch.Parent := FDocPanel;
  FDocSearch.Position.X := 60;
  FDocSearch.Position.Y := 54;
  FDocSearch.Width := 300;
  FDocSearch.TextPrompt := 'Комментарий, тип или № документа...';
  FDocSearch.OnChange := DocsSearchChange;

  FDocSearchTimer := TTimer.Create(Self);
  FDocSearchTimer.Interval := 350;
  FDocSearchTimer.Enabled := False;
  FDocSearchTimer.OnTimer := SearchTimerTimer;

  // Порядок создания = порядок прижатия к низу: статус ниже всех,
  // затем сплиттер, затем грид строк. Реестр (Client) создаётся последним
  // и занимает остаток.
  //
  // --- Статус ---
  FDocStatus := TText.Create(Self);
  FDocStatus.Parent := FTabDocs;
  FDocStatus.Align := TAlignLayout.Bottom;
  FDocStatus.Height := 30;
  FDocStatus.Text := 'Нажмите "Обновить" для загрузки реестра';

  // --- Нижняя часть: расшифровка выбранного документа ---
  // Реестр показывает только шапки. Что именно ушло из какой партии —
  // это DocumentLine, и без него реестр не отвечает на главный вопрос
  // «откуда списали». Второй грид привязан к выделению строки реестра.
  FLineSplitter := TSplitter.Create(Self);
  FLineSplitter.Parent := FTabDocs;
  FLineSplitter.Align := TAlignLayout.Bottom;
  FLineSplitter.Height := 6;

  FLineGrid := TGrid.Create(Self);
  FLineGrid.Parent := FTabDocs;
  FLineGrid.Align := TAlignLayout.Bottom;
  FLineGrid.Height := 220;

  // Подпись — иначе два грида подряд читаются как один список.
  FLineCaption := TText.Create(Self);
  FLineCaption.Parent := FTabDocs;
  FLineCaption.Align := TAlignLayout.Bottom;
  FLineCaption.Height := 24;
  FLineCaption.Text := 'Строки документа (нажмите на документ в таблице выше)';
  FLineCaption.VertTextAlign := TTextAlign.Leading;

  // --- Реестр ---
  FDocGrid := TGrid.Create(Self);
  FDocGrid.Parent := FTabDocs;
  FDocGrid.Align := TAlignLayout.Client;
  // Строка выделяется целиком: по ней строится нижняя таблица, и подсветка
  // одной ячейки не давала понять, что «выбран документ», а не поле.
  FDocGrid.Options := FDocGrid.Options + [TGridOption.RowSelect];
  // Выделили строку — подгрузили её строки в нижний грид.
  FDocGrid.OnSelectCell := LoadDocumentLines;
end;

// Колонки расшифровки документа.
procedure TFormMain.CreateLineColumns;
begin
  FLineBindings := TBindingsList.Create(Self);
  FLineBindSource := TBindSourceDB.Create(Self);
  FLineLink := TLinkGridToDataSource.Create(Self);
  FLineLink.GridControl := FLineGrid;
  FLineLink.DataSource := FLineBindSource;

  with FLineLink.Columns.Add do
  begin
    MemberName := 'BatchId';
    Header     := 'Партия';
    Width      := 70;
  end;
  with FLineLink.Columns.Add do
  begin
    MemberName := 'GoodsName';
    Header     := 'Товар';
    Width      := 160;
  end;
  with FLineLink.Columns.Add do
  begin
    MemberName := 'PlaceFromName';
    Header     := 'Откуда';
    Width      := 130;
  end;
  with FLineLink.Columns.Add do
  begin
    MemberName := 'PlaceToName';
    Header     := 'Куда';
    Width      := 130;
  end;
  with FLineLink.Columns.Add do
  begin
    MemberName    := 'Quantity';
    Header        := 'Кол-во';
    Width         := 90;
    DecimalDigits := 3;
  end;
  with FLineLink.Columns.Add do
  begin
    MemberName    := 'Price';
    Header        := 'Цена';
    Width         := 90;
    DecimalDigits := 2;
  end;
end;

// Выделили документ в реестре — показали его строки.
procedure TFormMain.LoadDocumentLines(Sender: TObject; const ACol, ARow: Integer;
  var CanSelect: Boolean);
var
  DS: TDataSet;
  DocId: Int64;
begin
  // OnSelectCell срабатывает уже при построении колонок реестра — до того,
  // как CreateLineColumns создаст привязку нижнего грида. Без этой защиты
  // обращение к FLineBindSource даёт AV на старте.
  if FLineBindSource = nil then
    Exit;
  if ARow < 0 then
  begin
    FLineBindSource.DataSet := nil;
    Exit;
  end;
  // Колонка 0 — DocumentId (первая в CreateDocsColumns).
  // GetValue возвращает TValue, и у привязанного грида внутри лежит не
  // целое число, а значение поля — AsInt64 на нём бросает EInvalidCast
  // («Invalid class typecast»). ToString + StrToInt64Def безопаснее.
  DocId := StrToInt64Def(FDocGrid.Model.GetValue(0, ARow, False).ToString, 0);
  if DocId <= 0 then
    Exit;
  try
    DS := DM.OpenDocumentLines(DocId);
    FLineBindSource.DataSet := DS;
  except
    on E: Exception do
      FDocStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

procedure TFormMain.CreateDocsColumns;
begin
  FDocBindings := TBindingsList.Create(Self);
  FDocBindSource := TBindSourceDB.Create(Self);
  FDocLink := TLinkGridToDataSource.Create(Self);
  FDocLink.GridControl := FDocGrid;
  FDocLink.DataSource := FDocBindSource;

  with FDocLink.Columns.Add do
  begin
    MemberName := 'DocumentId';
    Header     := '№ док';
    Width      := 70;
  end;
  with FDocLink.Columns.Add do
  begin
    MemberName := 'DocTypeName';
    Header     := 'Тип';
    Width      := 110;
  end;
  with FDocLink.Columns.Add do
  begin
    MemberName := 'DocDate';
    Header     := 'Дата';
    Width      := 160;
  end;
  with FDocLink.Columns.Add do
  begin
    MemberName := 'Comment';
    Header     := 'Комментарий';
    Width      := 200;
  end;
  with FDocLink.Columns.Add do
  begin
    MemberName := 'LineCount';
    Header     := 'Строк';
    Width      := 70;
  end;
  with FDocLink.Columns.Add do
  begin
    MemberName    := 'TotalQty';
    Header        := 'Кол-во';
    Width         := 90;
    DecimalDigits := 3;
  end;
end;

procedure TFormMain.LoadDocs(Sender: TObject);
var
  DS: TDataSet;
  FromDate, ToDate: TDateTime;
  DocType: Integer;
  CanSel: Boolean;
begin
  FromDate := Trunc(FDocFrom.Date);
  // "До" = начало следующих суток (полунеинтервал [From, To)).
  ToDate := Trunc(FDocTo.Date) + 1;

  // 0 = Все, 1 = Приход, 2 = Перемещение, 3 = Расход.
  DocType := FDocTypeCb.ItemIndex;

  try
    if FDocBindSource.DataSet <> nil then
      FDocBindSource.DataSet.Close;
    DS := DM.OpenDocuments(FromDate, ToDate, DocType, FDocSearch.Text);
    FDocBindSource.DataSet := DS;
    if DS.RecordCount = 0 then
    begin
      FDocStatus.Text := 'Документов не найдено';
      FLineBindSource.DataSet := nil;
    end
    else
    begin
      FDocStatus.Text := Format('Найдено документов: %d%s',
        [DS.RecordCount,
         IfThen(FDocSearch.Text.Trim <> '',
           ' (фильтр «' + FDocSearch.Text.Trim + '»)', '')]);
      // Сразу показываем строки первого документа: пустой нижний грид
      // читается как «не работает», а не как «выберите документ».
      FDocGrid.SelectRow(0);
      CanSel := True;
      LoadDocumentLines(FDocGrid, 0, 0, CanSel);
    end;
  except
    on E: Exception do
      FDocStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// ============================================================================
// Вкладка "Перемещение" (SPECIFICATION.md II.2.3, DocType=2)
//
//   [Товар ▼]  [Партия ▼ (№ · место · остаток)]  [Кол-во]
//   [Дата]     [Время]                            [Комментарий]
//   [Место назначения ▼]  [Переместить]
//
// Перемещается ЧАСТЬ партии: старая партия уменьшается, на новом месте
// создаётся новая с той же ценой и датой прихода.
// ============================================================================

procedure TFormMain.CreateTransferControls;
var
  Y: Single;
begin
  FTrPanel := TPanel.Create(Self);
  FTrPanel.Parent := FTabTransfer;
  FTrPanel.Align := TAlignLayout.Top;
  FTrPanel.Height := 160;

  Y := 12;

  // --- Строка 1: Товар / выбранная партия / Количество ---
  MakeLabel('Товар', 10, Y + 5, 50, FTrPanel);
  FTrGoodsCb := TComboBox.Create(Self);
  FTrGoodsCb.Parent := FTrPanel;
  FTrGoodsCb.Position.X := 65;
  FTrGoodsCb.Position.Y := Y;
  FTrGoodsCb.Width := 200;
  FTrGoodsCb.OnChange := TransferGoodsCbChange;

  // Партия не выбирается комбобоксом: она выбирается в гриде ниже.
  // Раньше их было два, и это сбивало — непонятно, где именно выбирать.
  MakeLabel('Выбрано', 280, Y + 5, 60, FTrPanel);
  FTrPicked := TText.Create(Self);
  FTrPicked.Parent := FTrPanel;
  FTrPicked.Position.X := 345;
  FTrPicked.Position.Y := Y + 5;
  FTrPicked.Width := 330;
  FTrPicked.Height := 20;
  FTrPicked.Align := TAlignLayout.None;
  FTrPicked.VertTextAlign := TTextAlign.Leading;
  FTrPicked.Text := 'партия не выбрана — нажмите на строку в таблице';

  MakeLabel('Кол-во', 690, Y + 5, 45, FTrPanel);
  FTrQty := TEdit.Create(Self);
  FTrQty.Parent := FTrPanel;
  FTrQty.Position.X := 740;
  FTrQty.Position.Y := Y;
  FTrQty.Width := 90;
  FTrQty.Text := '1';

  // --- Строка 2: Дата / Время / Комментарий ---
  Y := 54;
  MakeLabel('Дата', 10, Y + 5, 40, FTrPanel);
  FTrDate := TDateEdit.Create(Self);
  FTrDate.Parent := FTrPanel;
  FTrDate.Position.X := 55;
  FTrDate.Position.Y := Y;
  FTrDate.Width := 120;
  FTrDate.Date := Now;

  MakeLabel('Время', 190, Y + 5, 45, FTrPanel);
  FTrTime := TTimeEdit.Create(Self);
  FTrTime.Parent := FTrPanel;
  FTrTime.Position.X := 240;
  FTrTime.Position.Y := Y;
  FTrTime.Width := 110;
  FTrTime.UseNowTime := True;

  MakeLabel('Комментарий', 365, Y + 5, 80, FTrPanel);
  FTrComment := TEdit.Create(Self);
  FTrComment.Parent := FTrPanel;
  FTrComment.Position.X := 450;
  FTrComment.Position.Y := Y;
  FTrComment.Width := 340;

  // --- Строка 3: Место назначения + кнопка ---
  Y := 96;
  MakeLabel('Куда', 10, Y + 5, 40, FTrPanel);
  FTrPlaceCb := TComboBox.Create(Self);
  FTrPlaceCb.Parent := FTrPanel;
  FTrPlaceCb.Position.X := 55;
  FTrPlaceCb.Position.Y := Y;
  FTrPlaceCb.Width := 300;

  FTrAddBtn := TButton.Create(Self);
  FTrAddBtn.Parent := FTrPanel;
  FTrAddBtn.Position.X := 370;
  FTrAddBtn.Position.Y := Y;
  FTrAddBtn.Width := 160;
  FTrAddBtn.Text := 'Переместить';
  FTrAddBtn.OnClick := TransferAddClick;

  FTrStatus := TText.Create(Self);
  FTrStatus.Parent := FTabTransfer;
  FTrStatus.Align := TAlignLayout.Bottom;
  FTrStatus.Height := 30;
  FTrStatus.Text := 'Выберите товар и партию';

  // --- Список партий выбранного товара ---
  // Раньше ниже формы было пустое место, хотя именно здесь нужен ответ
  // на вопрос «что и откуда можно переместить».
  FTrBatchGrid := TGrid.Create(Self);
  FTrBatchGrid.Parent := FTabTransfer;
  FTrBatchGrid.Align := TAlignLayout.Client;
  // Партия выбирается строкой целиком — так видно, что выбрана именно
  // запись, а не отдельная ячейка.
  FTrBatchGrid.Options := FTrBatchGrid.Options + [TGridOption.RowSelect];
  // Партия выбирается здесь, кликом по строке — так же, как в проводнике.
  FTrBatchGrid.OnSelectCell := TransferBatchSelected;
end;

procedure TFormMain.CreateTransferBatchColumns;
begin
  FTrBatchBindings := TBindingsList.Create(Self);
  FTrBatchBindSource := TBindSourceDB.Create(Self);
  FTrBatchLink := TLinkGridToDataSource.Create(Self);
  FTrBatchLink.GridControl := FTrBatchGrid;
  FTrBatchLink.DataSource := FTrBatchBindSource;

  with FTrBatchLink.Columns.Add do
  begin
    MemberName := 'BatchId';
    Header     := 'Партия';
    Width      := 70;
  end;
  with FTrBatchLink.Columns.Add do
  begin
    MemberName := 'WarehouseName';
    Header     := 'Склад';
    Width      := 150;
  end;
  with FTrBatchLink.Columns.Add do
  begin
    MemberName := 'PlaceName';
    Header     := 'Место';
    Width      := 90;
  end;
  with FTrBatchLink.Columns.Add do
  begin
    MemberName := 'IncomeDate';
    Header     := 'Приход';
    Width      := 150;
  end;
  with FTrBatchLink.Columns.Add do
  begin
    MemberName    := 'Price';
    Header        := 'Цена';
    Width         := 80;
    DecimalDigits := 2;
  end;
  with FTrBatchLink.Columns.Add do
  begin
    MemberName    := 'QtyLeft';
    Header        := 'Остаток';
    Width         := 90;
    DecimalDigits := 3;
  end;
end;

// Комбобоксы перемещения: товары (из справочника) и места (все, т.к. может
// быть перемещение между складами).
procedure TFormMain.FillTransferCombos;
var
  DS: TDataSet;
  Idx: Integer;
begin
  DS := DM.GoodsDataSet;
  FTrGoodsCb.Items.BeginUpdate;
  try
    FTrGoodsCb.Items.Clear;
    FTrGoodsIds := [];
    if DS.Active then
    begin
      DS.DisableControls;
      try
        DS.First;
        while not DS.Eof do
        begin
          FTrGoodsCb.Items.Add(DS.FieldByName('GoodsName').AsString);
          Idx := Length(FTrGoodsIds);
          SetLength(FTrGoodsIds, Idx + 1);
          FTrGoodsIds[Idx] := DS.FieldByName('GoodsId').AsLargeInt;
          DS.Next;
        end;
        DS.First;
      finally
        DS.EnableControls;
      end;
    end;
  finally
    FTrGoodsCb.Items.EndUpdate;
  end;

  DS := DM.PlacesDataSet;
  FTrPlaceCb.Items.BeginUpdate;
  try
    FTrPlaceCb.Items.Clear;
    FTrPlaceIds := [];
    if DS.Active then
    begin
      DS.DisableControls;
      try
        DS.First;
        while not DS.Eof do
        begin
          FTrPlaceCb.Items.Add(DS.FieldByName('WarehouseName').AsString + ' / ' +
            DS.FieldByName('PlaceName').AsString);
          Idx := Length(FTrPlaceIds);
          SetLength(FTrPlaceIds, Idx + 1);
          FTrPlaceIds[Idx] := DS.FieldByName('PlaceId').AsLargeInt;
          DS.Next;
        end;
        DS.First;
      finally
        DS.EnableControls;
      end;
    end;
  finally
    FTrPlaceCb.Items.EndUpdate;
  end;

  if Length(FTrGoodsIds) > 0 then
  begin
    FTrGoodsCb.ItemIndex := 0;
    TransferGoodsCbChange(nil);
  end
  else
    FTrGoodsCb.ItemIndex := -1;
end;

// Выбор товара → список его партий в гриде под формой.
procedure TFormMain.TransferGoodsCbChange(Sender: TObject);
var
  DS: TDataSet;
begin
  FTrSelBatchId := 0;
  FTrSelQty := 0;
  FTrPicked.Text := 'партия не выбрана — нажмите на строку в таблице';
  if (FTrGoodsCb.ItemIndex < 0) or (FTrGoodsCb.ItemIndex >= Length(FTrGoodsIds)) then
  begin
    FTrBatchBindSource.DataSet := nil;
    FTrStatus.Text := 'Выберите товар';
    Exit;
  end;
  try
    DS := DM.OpenBatchesForGoods(FTrGoodsIds[FTrGoodsCb.ItemIndex]);
    FTrBatchBindSource.DataSet := DS;
    if DS.RecordCount = 0 then
      FTrStatus.Text := 'У товара нет партий с остатком'
    else
      FTrStatus.Text := Format('Партий с остатком: %d — выберите строку', [DS.RecordCount]);
  except
    on E: Exception do
      FTrStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

// Клик по строке грида — запоминаем партию и её остаток.
procedure TFormMain.TransferBatchSelected(Sender: TObject; const ACol,
  ARow: Integer; var CanSelect: Boolean);
begin
  if ARow < 0 then
  begin
    FTrSelBatchId := 0;
    FTrSelQty := 0;
    FTrPicked.Text := 'партия не выбрана — нажмите на строку в таблице';
    Exit;
  end;
  // Колонка 0 — BatchId, 1 — склад, 2 — место, 5 — остаток (см. колонки).
  FTrSelBatchId := StrToInt64Def(
    FTrBatchGrid.Model.GetValue(0, ARow, False).ToString, 0);
  FTrSelQty := StrToFloatDef(
    StringReplace(FTrBatchGrid.Model.GetValue(5, ARow, False).ToString,
      ',', '.', [rfReplaceAll]), 0);
  FTrPicked.Text := Format('№%d · %s · %g шт',
    [FTrSelBatchId,
     FTrBatchGrid.Model.GetValue(2, ARow, False).ToString,
     FTrSelQty]);
  FTrStatus.Text := Format('Выбрана партия %d, доступно %g шт',
    [FTrSelBatchId, FTrSelQty]);
end;

// Кнопка «Переместить»: диалог подтверждения → DocumentTransfer.
procedure TFormMain.TransferAddClick(Sender: TObject);
var
  Qty: Double;
  DocDate: TDateTime;
  BatchId, PlaceId: Int64;
  DocId: Integer;
  Res: TModalResult;
  Msg: string;
begin
  if FTrSelBatchId <= 0 then
  begin
    FTrStatus.Text := 'Нажмите на строку в таблице, чтобы выбрать партию';
    Exit;
  end;
  if (FTrPlaceCb.ItemIndex < 0) or (FTrPlaceCb.ItemIndex >= Length(FTrPlaceIds)) then
  begin
    FTrStatus.Text := 'Выберите место назначения';
    Exit;
  end;
  if not ParseNum(FTrQty.Text, Qty) or (Qty <= 0) then
  begin
    FTrStatus.Text := 'Количество должно быть числом больше нуля';
    Exit;
  end;

  BatchId := FTrSelBatchId;
  PlaceId := FTrPlaceIds[FTrPlaceCb.ItemIndex];

  if Qty > FTrSelQty + 1e-9 then
  begin
    FTrStatus.Text := Format('В партии всего %g шт', [FTrSelQty]);
    Exit;
  end;

  DocDate := FTrDate.Date + FTrTime.Time;

  Msg := Format('Переместить %g шт из партии №%d в «%s»?',
    [Qty, BatchId, FTrPlaceCb.Text]);
  Res := TDialogServiceSync.MessageDialog(
    Msg, TMsgDlgType.mtConfirmation, mbYesNo, TMsgDlgBtn.mbNo, 0);
  if Res <> mrYes then
  begin
    FTrStatus.Text := 'Отменено пользователем';
    Exit;
  end;

  try
    DocId := DM.DocumentTransfer(BatchId, PlaceId, Qty, DocDate, FTrComment.Text);
    FTrStatus.Text := Format('Перемещение №%d: партия %d → %s, %g шт',
      [DocId, BatchId, FTrPlaceCb.Text, Qty]);
    FTrQty.Text := '1';
    // Партии изменились — перечитываем список.
    TransferGoodsCbChange(nil);
  except
    on E: Exception do
      FTrStatus.Text := 'Ошибка: ' + E.Message;
  end;
end;

end.
