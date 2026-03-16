// ============================================================================
// Horse.WebSocket.SocketIO.pas
// Protocolo Socket.IO v5 (camada sobre Engine.IO v4)
//
// Responsabilidades:
//   - Parse de pacotes Socket.IO (type + namespace + event + data + ack)
//   - Multiplexing por namespace
//   - Registro de handlers de eventos via .On('evento', handler)
//   - Emissão de eventos .Emit()
//   - Acknowledgments
// ============================================================================

unit Horse.WebSocket.SocketIO;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Generics.Collections,
  Horse.WebSocket.Types,
  Horse.WebSocket.Utils;

type
  // ---------------------------------------------------------------------------
  // Evento Socket.IO
  // ---------------------------------------------------------------------------
  TSocketIOEvent = record
    EventName : string;
    Data      : string;  // JSON string (array ou objeto)
    AckID     : Integer; // -1 se não requer ack
  end;

  // ---------------------------------------------------------------------------
  // Callback de evento Socket.IO
  // ClientID = SID da sessão Engine.IO
  // Data = payload JSON (array de argumentos)
  // AckFn = função para enviar acknowledgment (nil se não requer ack)
  // ---------------------------------------------------------------------------
  TSocketIOHandler = reference to procedure(
    const ClientID : string;
    const Data     : string;
    AckFn          : TProc<string>
  );

  // ---------------------------------------------------------------------------
  // TSocketIONamespace — namespace isolado (ex: '/', '/chat', '/admin')
  // ---------------------------------------------------------------------------
  TSocketIONamespace = class
  private
    FPath      : string;
    FHandlers  : TDictionary<string, TSocketIOHandler>;  // evento → handler
    FLock      : TCriticalSection;
    FClients   : TDictionary<string, Boolean>;           // clientID → connected
    FClientsLock: TCriticalSection;
  public
    constructor Create(const APath: string);
    destructor  Destroy; override;

    procedure RegisterHandler(const EventName: string; Handler: TSocketIOHandler);
    procedure ProcessEvent(const ClientID: string; const Event: TSocketIOEvent;
                           SendFn: TProc<string, string>);  // SendFn(ClientID, Packet)
    procedure AddClient(const ClientID: string);
    procedure RemoveClient(const ClientID: string);
    function  GetClients: TArray<string>;

    // API fluida
    procedure On_(const EventName: string; Handler: TSocketIOHandler);
    procedure Emit(const EventName, Data: string);

    property Path: string read FPath;
  end;

  // ---------------------------------------------------------------------------
  // TSocketIOManager — singleton que gerencia multi-namespace e eventos
  // ---------------------------------------------------------------------------
  TSocketIOManager = class
  private
    FNamespaces  : TDictionary<string, TSocketIONamespace>;
    FLock        : TCriticalSection;

    // Função de envio registrada pelo middleware WS
    // SendFn(clientID, engineIOPacket)
    FSendFn   : TProc<string, string>;

    class var FInstance: TSocketIOManager;

    function GetOrCreateNamespace(const Path: string): TSocketIONamespace;
  public
    constructor Create;
    destructor  Destroy; override;

    class function  Instance: TSocketIOManager;
    class procedure DestroyInstance;

    // Registra a função de envio (injetada pelo middleware)
    procedure SetSendFunction(Fn: TProc<string, string>);

    // Registra handler de evento em um namespace
    // Ex: On('/','chat message', handler) ou On('', 'event', handler) → namespace '/'
    procedure On(const Namespace, EventName: string; Handler: TSocketIOHandler); overload;
    procedure On(const EventName: string; Handler: TSocketIOHandler); overload; // namespace '/'

    // Emite evento para um cliente específico
    procedure EmitTo(const ClientID, EventName, Data: string); overload;
    procedure EmitTo(const ClientID, EventName, Data, Namespace: string); overload;

    // Broadcast para todos em um namespace
    procedure Broadcast(const EventName, Data: string; const Namespace: string = '/');

    // Chamado pelo middleware ao receber dados EIO tipo '4' (Socket.IO payload)
    procedure HandlePayload(const ClientID, Payload: string);

    // Chamado ao conectar/desconectar um cliente
    procedure HandleConnect(const ClientID, NamespacePath: string);
    procedure HandleDisconnect(const ClientID: string);

    // Monta um pacote Socket.IO event
    function  BuildEventPacket(const Namespace, EventName, Data: string;
                               AckID: Integer = -1): string;

    // Monta pacote EIO message (tipo 4) com payload Socket.IO
    function  BuildEIOMessage(const SIOPacket: string): string;

    // API fluida
    function Of_(const Namespace: string): TSocketIONamespace;
  end;

// Função global de acesso ao singleton
function SocketIO: TSocketIOManager;

// Parser de pacote Socket.IO raw
function ParseSocketIOPacket(const Raw: string; out PacketType: Char;
                              out Namespace, AckIDStr, Data: string): Boolean;

implementation

uses StrUtils;

// ============================================================================
// TSocketIONamespace
// ============================================================================

constructor TSocketIONamespace.Create(const APath: string);
begin
  inherited Create;
  FPath        := APath;
  FHandlers    := TDictionary<string, TSocketIOHandler>.Create;
  FLock        := TCriticalSection.Create;
  FClients     := TDictionary<string, Boolean>.Create;
  FClientsLock := TCriticalSection.Create;
end;

destructor TSocketIONamespace.Destroy;
begin
  FHandlers.Free;
  FLock.Free;
  FClients.Free;
  FClientsLock.Free;
  inherited;
end;

procedure TSocketIONamespace.RegisterHandler(const EventName: string;
                                             Handler: TSocketIOHandler);
begin
  FLock.Enter;
  try
    FHandlers.AddOrSetValue(EventName, Handler);
  finally
    FLock.Leave;
  end;
end;

procedure TSocketIONamespace.ProcessEvent(const ClientID: string;
                                          const Event: TSocketIOEvent;
                                          SendFn: TProc<string, string>);
var
  Handler: TSocketIOHandler;
  AckFn: TProc<string>;
  TheAckID: Integer;
begin
  FLock.Enter;
  try
    if not FHandlers.TryGetValue(Event.EventName, Handler) then Exit;
  finally
    FLock.Leave;
  end;

  TheAckID := Event.AckID;

  // Monta a função de ACK caso o cliente tenha solicitado
  if TheAckID >= 0 then
  begin
    AckFn := procedure(AckData: string)
    var
      AckPacket: string;
    begin
      // Socket.IO ACK packet: "3[<namespace>,]<ackID>[<data>]"
      // Para namespace padrão '/' não incluímos o path
      if (FPath = '/') or (FPath = '') then
        AckPacket := SIO_ACK + IntToStr(TheAckID) + AckData
      else
        AckPacket := SIO_ACK + FPath + ',' + IntToStr(TheAckID) + AckData;
      SendFn(ClientID, EIO_MESSAGE + AckPacket);
    end;
  end
  else
    AckFn := nil;

  Handler(ClientID, Event.Data, AckFn);
end;

procedure TSocketIONamespace.AddClient(const ClientID: string);
begin
  FClientsLock.Enter;
  try
    FClients.AddOrSetValue(ClientID, True);
  finally
    FClientsLock.Leave;
  end;
end;

procedure TSocketIONamespace.RemoveClient(const ClientID: string);
begin
  FClientsLock.Enter;
  try
    FClients.Remove(ClientID);
  finally
    FClientsLock.Leave;
  end;
end;

function TSocketIONamespace.GetClients: TArray<string>;
var
  I: Integer;
  Pair: TPair<string, Boolean>;
begin
  FClientsLock.Enter;
  try
    SetLength(Result, FClients.Count);
    I := 0;
    for Pair in FClients do
    begin
      Result[I] := Pair.Key;
      Inc(I);
    end;
  finally
    FClientsLock.Leave;
  end;
end;

procedure TSocketIONamespace.On_(const EventName: string; Handler: TSocketIOHandler);
begin
  RegisterHandler(EventName, Handler);
end;

procedure TSocketIONamespace.Emit(const EventName, Data: string);
begin
  // Broadcast para todos os clientes do namespace via o manager singleton
  TSocketIOManager.Instance.Broadcast(EventName, Data, FPath);
end;

// ============================================================================
// Parser de pacote Socket.IO
// Formato: <type>[<namespace>,][<ackID>]<data>
// Ex: "2/chat,42[\"hello\",{\"msg\":\"world\"}]"
//     "20[\"connect\",{\"sid\":\"...\"}]"  → type=2, ns='/', no-ack, data="0[...]"
// ============================================================================

function ParseSocketIOPacket(const Raw: string; out PacketType: Char;
                              out Namespace, AckIDStr, Data: string): Boolean;
var
  Pos: Integer;
  C: Char;
begin
  Result := False;
  Namespace  := '/';
  AckIDStr   := '';
  Data       := '';
  if Length(Raw) = 0 then Exit;

  PacketType := Raw[1];
  Pos := 2;

  // Namespace?
  if (Pos <= Length(Raw)) and (Raw[Pos] = '/') then
  begin
    Namespace := '';
    while (Pos <= Length(Raw)) and (Raw[Pos] <> ',') do
    begin
      Namespace := Namespace + Raw[Pos];
      Inc(Pos);
    end;
    // Pula a vírgula
    if (Pos <= Length(Raw)) and (Raw[Pos] = ',') then
      Inc(Pos);
  end;

  // AckID? (dígitos antes do '[' ou '{')
  AckIDStr := '';
  while (Pos <= Length(Raw)) and CharInSet(Raw[Pos], ['0'..'9']) do
  begin
    AckIDStr := AckIDStr + Raw[Pos];
    Inc(Pos);
  end;

  // Resto é data
  Data := Copy(Raw, Pos, MaxInt);
  Result := True;
end;

// ============================================================================
// TSocketIOManager
// ============================================================================


constructor TSocketIOManager.Create;
begin
  inherited;
  FNamespaces := TDictionary<string, TSocketIONamespace>.Create;
  FLock       := TCriticalSection.Create;
end;

destructor TSocketIOManager.Destroy;
var
  Pair: TPair<string, TSocketIONamespace>;
begin
  FLock.Enter;
  try
    for Pair in FNamespaces do
      Pair.Value.Free;
    FNamespaces.Clear;
  finally
    FLock.Leave;
  end;
  FNamespaces.Free;
  FLock.Free;
  inherited;
end;

class function TSocketIOManager.Instance: TSocketIOManager;
begin
  if not Assigned(FInstance) then
    FInstance := TSocketIOManager.Create;
  Result := FInstance;
end;

class procedure TSocketIOManager.DestroyInstance;
begin
  FreeAndNil(FInstance);
end;

function TSocketIOManager.GetOrCreateNamespace(const Path: string): TSocketIONamespace;
var
  NS: TSocketIONamespace;
begin
  FLock.Enter;
  try
    if not FNamespaces.TryGetValue(Path, NS) then
    begin
      NS := TSocketIONamespace.Create(Path);
      FNamespaces.Add(Path, NS);
    end;
    Result := NS;
  finally
    FLock.Leave;
  end;
end;

procedure TSocketIOManager.SetSendFunction(Fn: TProc<string, string>);
begin
  FSendFn := Fn;
end;

procedure TSocketIOManager.On(const Namespace, EventName: string;
                               Handler: TSocketIOHandler);
var
  NS: TSocketIONamespace;
  NSPath: string;
begin
  NSPath := Namespace;
  if NSPath = '' then NSPath := '/';
  NS := GetOrCreateNamespace(NSPath);
  NS.RegisterHandler(EventName, Handler);
end;

procedure TSocketIOManager.On(const EventName: string; Handler: TSocketIOHandler);
begin
  On('/', EventName, Handler);
end;

function TSocketIOManager.BuildEventPacket(const Namespace, EventName, Data: string;
                                           AckID: Integer): string;
var
  NSPart, AckPart, DataPart: string;
begin
  NSPart := '';
  if (Namespace <> '') and (Namespace <> '/') then
    NSPart := Namespace + ',';

  AckPart := '';
  if AckID >= 0 then
    AckPart := IntToStr(AckID);

  // Data: JSON array com eventName como primeiro elemento
  if Data = '' then
    DataPart := Format('["%s"]', [EventName])
  else
    DataPart := Format('["%s",%s]', [EventName, Data]);

  Result := SIO_EVENT + NSPart + AckPart + DataPart;
end;

function TSocketIOManager.BuildEIOMessage(const SIOPacket: string): string;
begin
  Result := EIO_MESSAGE + SIOPacket;
end;

function TSocketIOManager.Of_(const Namespace: string): TSocketIONamespace;
var
  NS: string;
begin
  NS := Namespace;
  if NS = '' then NS := '/';
  Result := GetOrCreateNamespace(NS);
end;

// Função global de acesso ao singleton
function SocketIO: TSocketIOManager;
begin
  Result := TSocketIOManager.Instance;
end;

procedure TSocketIOManager.EmitTo(const ClientID, EventName, Data: string);
begin
  EmitTo(ClientID, EventName, Data, '/');
end;

procedure TSocketIOManager.EmitTo(const ClientID, EventName, Data, Namespace: string);
var
  SIOPacket: string;
begin
  if not Assigned(FSendFn) then Exit;
  SIOPacket := BuildEventPacket(Namespace, EventName, Data);
  FSendFn(ClientID, BuildEIOMessage(SIOPacket));
end;

procedure TSocketIOManager.Broadcast(const EventName, Data: string;
                                     const Namespace: string);
var
  NS: TSocketIONamespace;
  Clients: TArray<string>;
  ClientID: string;
begin
  if not Assigned(FSendFn) then Exit;
  FLock.Enter;
  try
    if not FNamespaces.TryGetValue(Namespace, NS) then Exit;
  finally
    FLock.Leave;
  end;

  Clients := NS.GetClients;
  for ClientID in Clients do
    EmitTo(ClientID, EventName, Data, Namespace);
end;

procedure TSocketIOManager.HandleConnect(const ClientID, NamespacePath: string);
var
  NS: TSocketIONamespace;
  NSPath, ConnectResponse: string;
begin
  NSPath := NamespacePath;
  if NSPath = '' then NSPath := '/';

  NS := GetOrCreateNamespace(NSPath);
  NS.AddClient(ClientID);

  // Resposta de CONNECT com o SID
  ConnectResponse := SIO_CONNECT;
  if NSPath <> '/' then
    ConnectResponse := ConnectResponse + NSPath + ',';
  ConnectResponse := ConnectResponse + Format('{"sid":"%s"}', [ClientID]);

  if Assigned(FSendFn) then
    FSendFn(ClientID, BuildEIOMessage(ConnectResponse));
end;

procedure TSocketIOManager.HandleDisconnect(const ClientID: string);
var
  Pair: TPair<string, TSocketIONamespace>;
begin
  FLock.Enter;
  try
    for Pair in FNamespaces do
      Pair.Value.RemoveClient(ClientID);
  finally
    FLock.Leave;
  end;
end;

procedure TSocketIOManager.HandlePayload(const ClientID, Payload: string);
var
  PacketType: Char;
  Namespace, AckIDStr, Data: string;
  NS: TSocketIONamespace;
  Event: TSocketIOEvent;
  AckID: Integer;

  // Extrai o eventName do JSON array "[\"eventName\",...]"
  function ExtractEventName(const JSONArr: string): string;
  var
    Start, Finish: Integer;
  begin
    Result := '';
    Start := Pos('"', JSONArr);
    if Start = 0 then Exit;
    Inc(Start);
    Finish := PosEx('"', JSONArr, Start);
    if Finish > 0 then
      Result := Copy(JSONArr, Start, Finish - Start);
  end;

  function ExtractEventData(const JSONArr, EventName: string): string;
  var
    CommaPos: Integer;
  begin
    // Remove o primeiro elemento (event name) do array
    // Ex: ["chat",{"msg":"hello"}] → {"msg":"hello"}
    // NÃO re-envolver em colchetes — BuildEventPacket já monta o array
    CommaPos := Pos(',' , JSONArr);
    if CommaPos > 0 then
      Result := TrimLeft(Copy(JSONArr, CommaPos + 1, Length(JSONArr) - CommaPos - 1))
    else
      Result := '';
  end;

begin
  if not ParseSocketIOPacket(Payload, PacketType, Namespace, AckIDStr, Data) then Exit;

  case PacketType of
    '0': // CONNECT
      HandleConnect(ClientID, Namespace);

    '1': // DISCONNECT
      begin
        FLock.Enter;
        try
          if FNamespaces.TryGetValue(Namespace, NS) then
            NS.RemoveClient(ClientID);
        finally
          FLock.Leave;
        end;
      end;

    '2': // EVENT
      begin
        FLock.Enter;
        try
          FNamespaces.TryGetValue(Namespace, NS);
        finally
          FLock.Leave;
        end;
        if not Assigned(NS) then Exit;

        if AckIDStr <> '' then
          AckID := StrToIntDef(AckIDStr, -1)
        else
          AckID := -1;

        Event.EventName := ExtractEventName(Data);
        Event.Data      := ExtractEventData(Data, Event.EventName);
        Event.AckID     := AckID;

        if Event.EventName <> '' then
          NS.ProcessEvent(ClientID, Event,
            procedure(CID, Pkt: string)
            begin
              if Assigned(FSendFn) then
                FSendFn(CID, Pkt);
            end);
      end;

    '3': // ACK — cliente respondeu uma ack (não precisamos processar no servidor básico)
      ; // TODO: implementar callbacks de ack do servidor

    else
      ; // pacotes binários (5, 6) — para implementação futura
  end;
end;

initialization
finalization
  TSocketIOManager.DestroyInstance;

end.
