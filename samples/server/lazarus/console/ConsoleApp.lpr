program ConsoleApp;

{$MODE DELPHI}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}

  SysUtils,
  Classes,
  Horse,
  Horse.Jhonson,
  Horse.WebSocket,
  consoleapp.websocket;

procedure DoGetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('Poooong');
end;

procedure DoGetClients(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send(Format('{"count":%d}', [WSClients.ClientCount]));
end;

procedure DoPostSendMessage(Req: THorseRequest; Res: THorseResponse);
  var Msg: string;
begin
  Msg := Req.Body;
  if Msg = '' then Msg := 'Mensagem via API HTTP';
  WSClients.Broadcast('[Servidor API] ' + Msg);
  // Interop: envia também para todos os clientes Socket.IO v4
  SocketIO.Of_('/').Emit('chat message', '"' + EscapeJsonStr('[Servidor API] ' + Msg) + '"');
  Res.Send('{"success": true, "message": "Enviado para todos"}');
end;

procedure DoRegistryHandlersSocketIo(const ClientID: string; const Data: string; AckFn: TProc<string>)
begin
    SafeWriteLn('[SIO] ' + ClientID + ' → ' + Data);

    // Broadcast para todos os clientes Socket.IO v4
    SocketIO.Of_('/').Emit('chat message', Data);

    // Interop: envia também para todos os clientes RFC 6455 (WS puro)
    // UnquoteJsonStr remove as aspas e escapes JSON do payload string
    WSClients.Broadcast('[SIO/' + ClientID + '] ' + UnquoteJsonStr(Data));
end;


procedure DoHorseMsgStart
begin
  WriteLn('[OK] Servidor iniciado. Ctrl+C para parar.');
end

begin
  WriteLn('=== Horse WebSocket — Echo Server (WS puro) ===');
  WriteLn('Horse HTTP : http://localhost:9000/api/ping');
  WriteLn('WebSocket  : ws://localhost:9001/ws');
  WriteLn('Demo HTML  : abra samples/client/rfc6455/index.html no browser');
  WriteLn('Demo HTML  : abra samples/client/socketio/index.html no browser');
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
    .Get('/api/ping', DoGetPing())
    .Get('/api/clients', DoGetClients())
    .Post('/api/sendmessage', DoPostSendMessage()); // Novo endpoint POST para enviar mensagem para todos os clientes


  SocketIO.Of_('/').On_('chat message', DoRegistryHandlersSocketIo() // Registra handlers Socket.IO
  );


  THorse.Get('/ping', GetPing);
  THorse.Listen(9000, DoHorseMsgStart);
end.
