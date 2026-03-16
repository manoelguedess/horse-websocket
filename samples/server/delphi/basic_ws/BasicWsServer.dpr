(*******************************************************************************************

## dependencies
- https://github.com/HashLoad/horse
- https://github.com/geby/synapse
- https://github.com/Robert-112/Bauglir-WebSocket-2


## inpired
- https://github.com/WillHubner/Horse-SocketIO


*******************************************************************************************)

program BasicWsServer;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  Horse,
  Horse.Jhonson,
  Horse.WebSocket,
  Horse.WebSocket.Types,
  Horse.WebSocket.Server,
  Horse.WebSocket.SocketIO;

var
  WS: THorseWSServer;

// Escapa uma string para uso dentro de um JSON string literal
// Ex: 'dizia "olá"' → 'dizia \"olá\"'
function EscapeJsonStr(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
end;

// Remove as aspas externas e os escapes de um valor JSON string
// Ex: '"dizia \"olá\""' → 'dizia "olá"'
function UnquoteJsonStr(const S: string): string;
begin
  Result := S;
  if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
  begin
    Result := Copy(Result, 2, Length(Result) - 2);
    Result := StringReplace(Result, '\"', '"', [rfReplaceAll]);
    Result := StringReplace(Result, '\\', '\', [rfReplaceAll]);
    Result := StringReplace(Result, '\n', #10, [rfReplaceAll]);
    Result := StringReplace(Result, '\r', #13, [rfReplaceAll]);
    Result := StringReplace(Result, '\t', #9, [rfReplaceAll]);
  end;
end;

// Protege a escrita no console de EInOutError em ambiente multithread
procedure SafeWriteLn(const Msg: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      WriteLn(Msg);
    end);
end;

procedure OnClientConnect(const ClientID: TWSClientID);
begin
  SafeWriteLn('[ + ] Cliente conectado: ' + ClientID);
  SafeWriteLn('      Total conectados: ' + IntToStr(WSClients.ClientCount));
end;

procedure OnClientDisconnect(const ClientID: TWSClientID);
begin
  SafeWriteLn('[ - ] Cliente desconectado: ' + ClientID);
end;

procedure OnClientMessage(const ClientID: TWSClientID; const Data: string);
var
  FormattedMsg: string;
begin
  SafeWriteLn('[MSG] ' + ClientID + ' → ' + Data);
  FormattedMsg := '[' + ClientID + '] disse: ' + Data;

  // Broadcast para todos os clientes RFC 6455 (WS puro)
  WSClients.Broadcast(FormattedMsg);

  // Interop: envia também para todos os clientes Socket.IO v4
  SocketIO.Of_('/').Emit('chat message', '"' + EscapeJsonStr(FormattedMsg) + '"');
end;

// Thread para enviar Ping periodicamente e manter as conexões vivas
// NOTA: Não é mais necessária — o Engine.IO já gerencia heartbeat automaticamente.
// Mantida apenas para referência.
{procedure StartKeepAlivePing;
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      Clients: TArray<IWSClient>;
      Client: IWSClient;
    begin
      while True do
      begin
        Sleep(30000); // 30 segundos
        try
          Clients := WSClients.GetClients;
          for Client in Clients do
          begin
            if Client.IsConnected then
              Client.Ping('ping');
          end;
        except
          // Evita que a thread morra se WSClients estiver sendo destruído
        end;
      end;
    end
  ).Start;
end;}

begin
  WriteLn('=== Horse WebSocket — Echo Server (WS puro) ===');
  WriteLn('Horse HTTP : http://localhost:9000/api/ping');
  WriteLn('WebSocket  : ws://localhost:9001/ws');
  WriteLn('Demo HTML  : abra samples/client/rfc6455/index.html no browser');
  WriteLn('Demo HTML  : abra samples/client/socketio/index.html no browser');
  WriteLn('');

  // Configura callbacks do WebSocket
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

