program Warehouse;

{ Warehouse — FMX-приложение «Складской учёт». Точка входа.

  DM создаётся здесь, а не в форме: соединение с БД должно жить столько,
  сколько работает приложение, а не одна форма. Порядок важен — конструктор
  TFormMain в FillIncomeCombos читает DM.GoodsDataSet, поэтому DM обязан
  существовать ДО Application.CreateForm.

  Неотловленное исключение в GUI закрывает окно без объяснений, поэтому
  текст ошибки пишется в Warehouse.log рядом с exe. }

uses
  System.StartUpCopy,     // стандартная строка FMX-шаблона (для мобильных копает ассеты, на Windows пустая)
  System.SysUtils,
  System.Classes,         // TStringList.SaveToFile — лог ошибок на диск
  FireDAC.FMXUI.Wait,     // TFDGUIxWaitCursor factory для FMX — без этого падение при открытии FD-запросов
  FMX.Forms,
  FMX.DialogService.Sync, // ShowMessage — показать ошибку пользователю
  MainForm in 'Source\Forms\MainForm.pas' {FormMain},
  uDM in 'Source\Data\uDM.pas';

{$R *.res}

// Пишем ошибку в файл рядом с exe и показываем диалог: без этого падение
// выглядит как «приложение просто закрылось».
procedure LogAndShowError(const E: Exception);
var
  LogFile: string;
  Log: TStringList;
begin
  LogFile := ExtractFilePath(ParamStr(0)) + 'Warehouse.log';
  Log := TStringList.Create;
  try
    try
      // дописываем поверх старого: FileExists защищён try — недоступный диск
      // не должен мешать показать диалог
      if FileExists(LogFile) then
        Log.LoadFromFile(LogFile);
      Log.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' +
        E.ClassName + ': ' + E.Message);
      Log.SaveToFile(LogFile);
    except
      // диск недоступен — диалог важнее лога
    end;
  finally
    Log.Free;
  end;
  try
    TDialogServiceSync.ShowMessage(E.ClassName + ': ' + E.Message);
  except
    // диалог тоже не поднялся — лог на диске уже есть
  end;
end;

begin
  try
    DM := TDM.Create(nil);
    try
      Application.Initialize;
      Application.CreateForm(TFormMain, FormMain);
      Application.Run;
    finally
      FreeAndNil(DM);
    end;
  except
    on E: Exception do
      LogAndShowError(E);
  end;
end.
