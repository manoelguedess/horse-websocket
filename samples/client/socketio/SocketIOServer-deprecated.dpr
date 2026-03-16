// ============================================================================
// SocketIOServer.dpr
// Sample: Chat Room usando Socket.IO v5
// Compatível com socket.io-client v4 no browser
// ============================================================================

program SocketIOServer;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  SysUtils,
  Horse,
  Horse.WebSocket,
  Horse.WebSocket.Types;

begin
  WriteLn('=== Horse WebSocket — Socket.IO Chat Server ===');
  WriteLn('Horse HTTP  : http://localhost:9000');
  WriteLn('Socket.IO   : http://localhost:9001 (Engine.IO polling + WS upgrade)');
  WriteLn('Demo HTML   : abra samples/socketio/index.html no browser');
  WriteLn('');

  // Configura porta WS separada para Engine.IO
  var Cfg := DefaultWSConfig;
  Cfg.WSPort := 9001;

  // Registra handlers Socket.IO
  // Namespace padrão '/'
  SocketIO.On('chat message', procedure(const ClientID, Data: string; AckFn: TProc<string>)
  begin
    WriteLn('[CHAT] ', ClientID, ': ', Data);
    // Broadcast para todos no namespace '/'
    SocketIO.Broadcast('chat message', Data);
    // Se o cliente pediu ack, confirma
    if Assigned(AckFn) then
      AckFn('"recebido"');
  end);

  SocketIO.On('ping', procedure(const ClientID, Data: string; AckFn: TProc<string>)
  begin
    WriteLn('[PING] ', ClientID);
    SocketIO.EmitTo(ClientID, 'pong', '"pong from server"');
  end);

  SocketIO.On('join room', procedure(const ClientID, Data: string; AckFn: TProc<string>)
  begin
    WriteLn('[ROOM] ', ClientID, ' entrou em: ', Data);
    SocketIO.EmitTo(ClientID, 'room joined', Data);
    SocketIO.Broadcast('user joined', Format('{"id":"%s","room":%s}', [ClientID, Data]));
  end);

  // Callback de conectar/desconectar (via WSClients)
  WSClients.OnConnect := procedure(const ClientID: string)
  begin
    WriteLn('[ + ] Socket.IO cliente: ', ClientID, ' (total: ', WSClients.ClientCount, ')');
  end;

  WSClients.OnDisconnect := procedure(const ClientID: string)
  begin
    WriteLn('[ - ] Desconectado: ', ClientID);
    SocketIO.Broadcast('user disconnected', Format('{"id":"%s"}', [ClientID]));
  end;

  THorse
    .Use(HorseWebSocket(Cfg))
    .Get('/', procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      // Serve o index.html
      Res.Send('<html><body><a href="index.html">Abra index.html no browser</a></body></html>');
    end);

  THorse.Listen(9000, procedure
  begin
    WriteLn('[OK] Servidor iniciado. Ctrl+C para parar.');
  end);
end.
