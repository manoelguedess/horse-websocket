// ============================================================================
// Horse.WebSocket.Server.pas
// Gerenciador de clientes WebSocket
// Envolve TWebSocketServer (biot2/WebSocket.pas) e expõe API pública.
// ============================================================================

unit Horse.WebSocket.Server;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Generics.Collections,
  WebSocket.Core,
  Horse.WebSocket.Types;

type
  // ---------------------------------------------------------------------------
  // TWSClientAdapter
  // Adapta TWebSocketServerConnection para IWSClient
  // ---------------------------------------------------------------------------
  TWSClientAdapter = class(TInterfacedObject, IWSClient)
  private
    FID         : TWSClientID;
    FConnection : TWebSocketServerConnection;
    FProtocol   : TWSProtocolMode;
    FRemoteIP   : string;
  public
    constructor Create(const AID: TWSClientID;
                       AConn: TWebSocketServerConnection;
                       AProtocol: TWSProtocolMode;
                       const ARemoteIP: string);

    // IWSClient
    function  GetID: TWSClientID;
    function  GetProtocol: TWSProtocolMode;
    function  GetRemoteIP: string;
    function  IsConnected: Boolean;
    procedure SendText(const Msg: string);
    procedure SendBinary(const Data: TBytes);
    procedure SendBinaryStream(const Data: TStream);
    procedure Ping(const Data: string);
    procedure Close;
  end;

  // ---------------------------------------------------------------------------
  // THorseWSClientMap — thread-safe map de ClientID → IWSClient
  // ---------------------------------------------------------------------------
  THorseWSClientMap = class
  private
    FLock   : TCriticalSection;
    FMap    : TDictionary<TWSClientID, IWSClient>;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure   Add(const ID: TWSClientID; Client: IWSClient);
    procedure   Remove(const ID: TWSClientID);
    function    TryGet(const ID: TWSClientID; out Client: IWSClient): Boolean;
    function    GetAll: TArray<IWSClient>;
    function    Count: Integer;
  end;

  // ---------------------------------------------------------------------------
  // THorseWSServer — fachada do servidor WebSocket
  // Não gerencia a porta TCP diretamente — delega ao TWebSocketServer
  // que é ativado pelo middleware via "sequestro" de socket do Indy.
  // ---------------------------------------------------------------------------
  THorseWSServer = class
  private
    FClients     : THorseWSClientMap;
    FOnConnect   : TWSOnConnect;
    FOnDisconnect: TWSOnDisconnect;
    FOnMessage   : TWSOnMessage;
    FOnBinary    : TWSOnBinary;
    FOnError     : TWSOnError;

    class var FInstance: THorseWSServer;
  public
    constructor Create;
    destructor  Destroy; override;

    // Singleton
    class function Instance: THorseWSServer;
    class procedure DestroyInstance;

    // Chamados pelo middleware ao aceitar conexão / receber frames
    procedure RegisterClient(const ID: TWSClientID; Conn: TWebSocketServerConnection;
                             Protocol: TWSProtocolMode; const RemoteIP: string);
    procedure UnregisterClient(const ID: TWSClientID);
    procedure HandleMessage(const ClientID: TWSClientID; const Data: string);
    procedure HandleBinary(const ClientID: TWSClientID; const Data: TBytes);

    // API pública para o desenvolvedor
    procedure SendTo(const ClientID: TWSClientID; const Msg: string);
    procedure SendBinaryTo(const ClientID: TWSClientID; const Data: TBytes);
    procedure Broadcast(const Msg: string);
    procedure BroadcastBinary(const Data: TBytes);
    procedure DisconnectClient(const ID: TWSClientID);
    function  GetClients: TArray<IWSClient>;
    function  GetClient(const ID: TWSClientID): IWSClient;
    function  ClientCount: Integer;

    // Eventos
    property OnConnect   : TWSOnConnect    read FOnConnect    write FOnConnect;
    property OnDisconnect: TWSOnDisconnect read FOnDisconnect write FOnDisconnect;
    property OnMessage   : TWSOnMessage    read FOnMessage    write FOnMessage;
    property OnBinary    : TWSOnBinary     read FOnBinary     write FOnBinary;
    property OnError     : TWSOnError      read FOnError      write FOnError;
  end;

implementation

// ============================================================================
// TWSClientAdapter
// ============================================================================

constructor TWSClientAdapter.Create(const AID: TWSClientID;
                                    AConn: TWebSocketServerConnection;
                                    AProtocol: TWSProtocolMode;
                                    const ARemoteIP: string);
begin
  inherited Create;
  FID         := AID;
  FConnection := AConn;
  FProtocol   := AProtocol;
  FRemoteIP   := ARemoteIP;
end;

function TWSClientAdapter.GetID: TWSClientID;
begin
  Result := FID;
end;

function TWSClientAdapter.GetProtocol: TWSProtocolMode;
begin
  Result := FProtocol;
end;

function TWSClientAdapter.GetRemoteIP: string;
begin
  Result := FRemoteIP;
end;

function TWSClientAdapter.IsConnected: Boolean;
begin
  Result := Assigned(FConnection) and (not FConnection.Closed);
end;

procedure TWSClientAdapter.SendText(const Msg: string);
var
  UTF8Bytes: TBytes;
  Raw: AnsiString;
begin
  if IsConnected then
  begin
    // Converter para UTF-8 antes de enviar — RFC 6455 exige UTF-8 em frames de texto.
    // AnsiString(Msg) usaria o code page do Windows, corrompendo caracteres como á, ç, etc.
    UTF8Bytes := TEncoding.UTF8.GetBytes(Msg);
    SetLength(Raw, Length(UTF8Bytes));
    if Length(UTF8Bytes) > 0 then
      Move(UTF8Bytes[0], Pointer(Raw)^, Length(UTF8Bytes));
    FConnection.SendText(Raw);
  end;
end;

procedure TWSClientAdapter.SendBinary(const Data: TBytes);
var
  MS: TMemoryStream;
begin
  if IsConnected and (Length(Data) > 0) then
  begin
    MS := TMemoryStream.Create;
    try
      MS.WriteBuffer(Data[0], Length(Data));
      MS.Position := 0;
      FConnection.SendBinary(MS);
    finally
      MS.Free;
    end;
  end;
end;

procedure TWSClientAdapter.SendBinaryStream(const Data: TStream);
begin
  if IsConnected and Assigned(Data) then
    FConnection.SendBinary(Data);
end;

procedure TWSClientAdapter.Ping(const Data: string);
var
  UTF8Bytes: TBytes;
  Raw: AnsiString;
begin
  if IsConnected then
  begin
    UTF8Bytes := TEncoding.UTF8.GetBytes(Data);
    SetLength(Raw, Length(UTF8Bytes));
    if Length(UTF8Bytes) > 0 then
      Move(UTF8Bytes[0], Pointer(Raw)^, Length(UTF8Bytes));
    FConnection.Ping(Raw);
  end;
end;

procedure TWSClientAdapter.Close;
begin
  if IsConnected then
    FConnection.Close(wsCloseNormal, 'Server closing connection');
end;

// ============================================================================
// THorseWSClientMap
// ============================================================================

constructor THorseWSClientMap.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FMap  := TDictionary<TWSClientID, IWSClient>.Create;
end;

destructor THorseWSClientMap.Destroy;
begin
  FMap.Free;
  FLock.Free;
  inherited;
end;

procedure THorseWSClientMap.Add(const ID: TWSClientID; Client: IWSClient);
begin
  FLock.Enter;
  try
    FMap.AddOrSetValue(ID, Client);
  finally
    FLock.Leave;
  end;
end;

procedure THorseWSClientMap.Remove(const ID: TWSClientID);
begin
  FLock.Enter;
  try
    FMap.Remove(ID);
  finally
    FLock.Leave;
  end;
end;

function THorseWSClientMap.TryGet(const ID: TWSClientID; out Client: IWSClient): Boolean;
begin
  FLock.Enter;
  try
    Result := FMap.TryGetValue(ID, Client);
  finally
    FLock.Leave;
  end;
end;

function THorseWSClientMap.GetAll: TArray<IWSClient>;
var
  I: Integer;
  Pair: TPair<TWSClientID, IWSClient>;
begin
  FLock.Enter;
  try
    SetLength(Result, FMap.Count);
    I := 0;
    for Pair in FMap do
    begin
      Result[I] := Pair.Value;
      Inc(I);
    end;
  finally
    FLock.Leave;
  end;
end;

function THorseWSClientMap.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FMap.Count;
  finally
    FLock.Leave;
  end;
end;

// ============================================================================
// THorseWSServer
// ============================================================================

constructor THorseWSServer.Create;
begin
  inherited;
  FClients := THorseWSClientMap.Create;
end;

destructor THorseWSServer.Destroy;
begin
  FClients.Free;
  inherited;
end;

class function THorseWSServer.Instance: THorseWSServer;
begin
  if not Assigned(FInstance) then
    FInstance := THorseWSServer.Create;
  Result := FInstance;
end;

class procedure THorseWSServer.DestroyInstance;
begin
  FreeAndNil(FInstance);
end;

procedure THorseWSServer.RegisterClient(const ID: TWSClientID;
                                        Conn: TWebSocketServerConnection;
                                        Protocol: TWSProtocolMode;
                                        const RemoteIP: string);
var
  Client: IWSClient;
begin
  Client := TWSClientAdapter.Create(ID, Conn, Protocol, RemoteIP);
  FClients.Add(ID, Client);
  if Assigned(FOnConnect) then
    FOnConnect(ID);
end;

procedure THorseWSServer.UnregisterClient(const ID: TWSClientID);
begin
  FClients.Remove(ID);
  if Assigned(FOnDisconnect) then
    FOnDisconnect(ID);
end;

procedure THorseWSServer.HandleMessage(const ClientID: TWSClientID; const Data: string);
begin
  if Assigned(FOnMessage) then
    FOnMessage(ClientID, Data);
end;

procedure THorseWSServer.HandleBinary(const ClientID: TWSClientID; const Data: TBytes);
begin
  if Assigned(FOnBinary) then
    FOnBinary(ClientID, Data);
end;

procedure THorseWSServer.SendTo(const ClientID: TWSClientID; const Msg: string);
var
  Client: IWSClient;
begin
  if FClients.TryGet(ClientID, Client) then
    Client.SendText(Msg);
end;

procedure THorseWSServer.SendBinaryTo(const ClientID: TWSClientID; const Data: TBytes);
var
  Client: IWSClient;
begin
  if FClients.TryGet(ClientID, Client) then
    Client.SendBinary(Data);
end;

procedure THorseWSServer.Broadcast(const Msg: string);
var
  Clients: TArray<IWSClient>;
  C: IWSClient;
begin
  Clients := FClients.GetAll;
  for C in Clients do
    if C.IsConnected then
      C.SendText(Msg);
end;

procedure THorseWSServer.BroadcastBinary(const Data: TBytes);
var
  Clients: TArray<IWSClient>;
  C: IWSClient;
begin
  Clients := FClients.GetAll;
  for C in Clients do
    if C.IsConnected then
      C.SendBinary(Data);
end;

procedure THorseWSServer.DisconnectClient(const ID: TWSClientID);
var
  Client: IWSClient;
begin
  if FClients.TryGet(ID, Client) then
    Client.Close;
end;

function THorseWSServer.GetClients: TArray<IWSClient>;
begin
  Result := FClients.GetAll;
end;

function THorseWSServer.GetClient(const ID: TWSClientID): IWSClient;
begin
  if not FClients.TryGet(ID, Result) then
    Result := nil;
end;

function THorseWSServer.ClientCount: Integer;
begin
  Result := FClients.Count;
end;

initialization
finalization
  THorseWSServer.DestroyInstance;

end.
