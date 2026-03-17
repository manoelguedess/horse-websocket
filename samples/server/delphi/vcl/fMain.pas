(*******************************************************************************************

## dependencies
- https://github.com/HashLoad/horse
- https://github.com/geby/synapse
- https://github.com/Robert-112/Bauglir-WebSocket-2


## inpired
- https://github.com/WillHubner/Horse-SocketIO


*******************************************************************************************)


unit fMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.Buttons
   ;

type
  TfrmMain = class(TForm)
    edtPort: TEdit;
    btnStart: TBitBtn;
    btnStop: TBitBtn;
    MemoLog: TMemo;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
  private
    procedure Status;
    procedure Start;
    procedure Stop;

    { Private declarations }
  public
    { Public declarations }
  end;

var
  frmMain: TfrmMain;

implementation

uses
  Horse,
  Horse.Jhonson,
  Horse.WebSocket,
  Horse.WebSocket.Types,
  Horse.WebSocket.Server,
  Horse.WebSocket.SocketIO,
  Horse.WebSocket.Utils,
  vclapp.websocket;

{$R *.dfm}

{ TfrmMain }

procedure TfrmMain.btnStartClick(Sender: TObject);
begin
  Start;
  Status;
end;

procedure TfrmMain.btnStopClick(Sender: TObject);
begin
  Stop;
  Status;
end;

procedure TfrmMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  if THorse.IsRunning then
    Stop;
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  edtPort.Text := '9000';
  MemoLog.Clear;
  {$REGION 'MemoLog'}
  MemoLog.Lines.Add('=== Horse WebSocket — Echo Server (WS puro & Socket.IO) ===');
  MemoLog.Lines.Add('Horse HTTP          : curl http://localhost:9000/api/ping');
  MemoLog.Lines.Add('WebSocket           : ws://localhost:9001/ws');
  MemoLog.Lines.Add('Demo RFC6455 HTML   : abra samples/client/rfc6455/index.html no browser');
  MemoLog.Lines.Add('Demo SocketIO HTML  : abra samples/client/socketio/index.html no browser');
  MemoLog.Lines.Add('Envia mensagem p/ todos os clientes conectados (Broadcast):');
  MemoLog.Lines.Add(' curl -X POST -H "Content-Type: application/json" http://localhost:9000/api/sendmessage -d "{\"msg\":\"pagamento efetuado\"}" ');
  MemoLog.Lines.Add('');
  {$ENDREGION}



  // Configura callbacks do WebSocket "UWebSocket.initialization"
  WS := WSClients;
  WS.OnConnect    := OnClientConnect;
  WS.OnDisconnect := OnClientDisconnect;
  WS.OnMessage    := OnClientMessage;


  // Configura o middleware (porta WS separada: 9001)
  Cfg := DefaultWSConfig;
  Cfg.WSPort := 9001;
  Cfg.AutoStart := False;  // Não iniciar WS ao registrar; inicia no btnStart

  THorse.Use(Jhonson);
  THorse.Use(HorseWebSocket(Cfg));


  OnWSLog := procedure(const Msg: string)
  begin
    TThread.Queue(nil, procedure begin MemoLog.Lines.Add(Msg) end);
  end;


  THorse.Get('ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Get('/api/ping', procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end)
    .Get('/api/clients', procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send(Format('{"count":%d}', [WSClients.ClientCount]));
    end)
    // Novo endpoint POST para enviar mensagem para todos os clientes
    .Post('/api/sendmessage', procedure(Req: THorseRequest; Res: THorseResponse)
    var
      Msg: string;
    begin
      Msg := Req.Body;
      if Msg = '' then Msg := 'Mensagem via API HTTP';
      WSClients.Broadcast('[Servidor API] ' + Msg);

      // Interop: envia tamb�m para todos os clientes Socket.IO v4
      SocketIO.Of_('/').Emit('chat message', '"' + EscapeJsonStr('[Servidor API] ' + Msg) + '"');

      Res.Send('{"success": true, "message": "Enviado para todos"}');
    end);

    RegistryHandleSocketIO;

end;

procedure TfrmMain.Start;
begin
  // Inicia o servidor WebSocket (RFC 6455 + Socket.IO/Engine.IO)
  HorseWebSocketStart;
  // Need to set "HORSE_VCL" compilation directive
  THorse.Listen(StrToInt(edtPort.Text));
end;

procedure TfrmMain.Status;
begin
  btnStop.Enabled := THorse.IsRunning;
  btnStart.Enabled := not THorse.IsRunning;
  edtPort.Enabled := not THorse.IsRunning;
end;

procedure TfrmMain.Stop;
begin
  THorse.StopListen;
  // Para o servidor WebSocket e limpa sessões/clientes
  HorseWebSocketStop;
end;

end.
