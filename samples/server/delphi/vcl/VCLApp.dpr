program VCLApp;

uses
  Vcl.Forms,
  fMain in 'fMain.pas' {frmMain},
  vclapp.websocket in 'vclapp.websocket.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
