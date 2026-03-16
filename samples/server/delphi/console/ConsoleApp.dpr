program ConsoleApp;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  Horse,
  Horse.Jhonson,
  Horse.WebSocket,
  consoleapp.websocket in 'consoleapp.websocket.pas';

begin
  WriteLn('=== Horse WebSocket — Echo Server (WS puro) ===');
  WriteLn('Horse HTTP : http://localhost:9000/api/ping');
  WriteLn('WebSocket  : ws://localhost:9001/ws');
  WriteLn('Demo HTML  : abra samples/basic_ws/index.html no browser');
  WriteLn('');

  // Configura callbacks do WebSocket "UWebSocket.initialization"
  WS := WSClients;
  WS.OnConnect    := OnClientConnect;
  WS.OnDisconnect := OnClientDisconnect;
  WS.OnMessage    := OnClientMessage;


  // Configura o middleware (porta WS separada: 9001)
  var Cfg := DefaultWSConfig;
  Cfg.WSPort := 9001;

  // Inicia o Horse com o middleware WebSocket
  THorse
    .Use(Jhonson)
    .Use(HorseWebSocket(Cfg))
    .Get('/api/ping', procedure(Req: THorseRequest; Res: THorseResponse)
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

      // Interop: envia também para todos os clientes Socket.IO v4
      SocketIO.Of_('/').Emit('chat message', '"' + EscapeJsonStr('[Servidor API] ' + Msg) + '"');

      Res.Send('{"success": true, "message": "Enviado para todos"}');
    end);

  // Registra handlers Socket.IO
  SocketIO.Of_('/').On_('chat message',
  procedure(const ClientID: string; const Data: string; AckFn: TProc<string>)
  begin
    SafeWriteLn('[SIO] ' + ClientID + ' → ' + Data);

    // Broadcast para todos os clientes Socket.IO v4
    SocketIO.Of_('/').Emit('chat message', Data);

    // Interop: envia também para todos os clientes RFC 6455 (WS puro)
    // UnquoteJsonStr remove as aspas e escapes JSON do payload string
    WSClients.Broadcast('[SIO/' + ClientID + '] ' + UnquoteJsonStr(Data));
  end
  );

  THorse.Listen(9000, procedure
  begin
    WriteLn('[OK] Servidor iniciado. Ctrl+C para parar.');
  end);


end.
