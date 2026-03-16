unit vclapp.websocket;

interface

uses
  System.SysUtils,
  System.Classes,
  Horse.WebSocket,
  Horse.WebSocket.Types,
  Horse.WebSocket.Server,
  Horse.WebSocket.SocketIO;


  procedure RegistryHandleSocketIO;

  /// <summary>
  ///   Escapa uma string para uso dentro de um JSON string literal
  ///   Ex: 'dizia "olá"' → 'dizia \"olá\"'
  /// </summary>
  function EscapeJsonStr(const S: string): string;
  /// <summary>
  /// Remove as aspas externas e os escapes de um valor JSON string
  /// Ex: '"dizia \"olá\""' → 'dizia "olá"'
  /// </summary>
  function UnquoteJsonStr(const S: string): string;
  /// <summary>
  ///   Protege a escrita no console de EInOutError em ambiente multithread
  /// </summary>
  procedure SafeWriteLn(const Msg: string);

  procedure OnClientConnect(const ClientID: TWSClientID);
  procedure OnClientDisconnect(const ClientID: TWSClientID);
  procedure OnClientMessage(const ClientID: TWSClientID; const Data: string);



var
  WS: THorseWSServer;
  Cfg : THorseWebSocketConfig;

implementation

uses
  Horse.WebSocket.Utils;

procedure RegistryHandleSocketIO;
begin
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
end;

function EscapeJsonStr(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
end;

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


procedure SafeWriteLn(const Msg: string);
begin
  //  TThread.Queue(nil,
  //    procedure
  //    begin
  //      WriteLn(Msg);
  //    end);

  SafeLog(Msg);  // delega para Horse.WebSocket.Utils.SafeLog (respeita OnWSLog)
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

end.




