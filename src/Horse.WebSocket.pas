// ============================================================================
// Horse.WebSocket.pas
// Middleware principal Horse-WebSocket
//
// Uso mínimo:
//   uses Horse, Horse.WebSocket;
//
//   THorse
//     .Use(HorseWebSocket)          // ativa WS + Engine.IO + Socket.IO
//     .Get('/api/test', ...);
//   THorse.Listen(9000);
//
// WebSocket puro (JS nativo):
//   const ws = new WebSocket('ws://host:9001/ws');
//
// Socket.IO:
//   const io = io('http://host:9000');
//   io.on('evento', fn);
// ============================================================================

unit Horse.WebSocket;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  WebSocket.Core,
  WebSocket.Helper,
  Horse,
  Horse.WebSocket.Types,
  Horse.WebSocket.Utils,
  Horse.WebSocket.Server,
  Horse.WebSocket.EngineIO,
  Horse.WebSocket.SocketIO,
  Horse.Exception.Interrupted;

type
  // ---------------------------------------------------------------------------
  // Alias público para facilitar uso
  // ---------------------------------------------------------------------------
  TWebSocketServer  = Horse.WebSocket.Server.THorseWSServer;
  TSocketIO         = Horse.WebSocket.SocketIO.TSocketIOManager;
  TEngineIO         = Horse.WebSocket.EngineIO.TEngineIOManager;

  // Alias para o tipo de middleware do Horse
  THorseMiddleware = THorseCallback;

  // ---------------------------------------------------------------------------
  // THorseWebSocketConfig — configurações do middleware
  // ---------------------------------------------------------------------------
  THorseWebSocketConfig = record
    WSPath       : string;   // path do WS puro (default: '/ws')
    EIOPath      : string;   // path engine.io (default: '/engine.io/')
    SIOPath      : string;   // path socket.io (default: '/socket.io/')
    AllowedOrigin: string;   // CORS (default: '*')
    TLSEnabled   : Boolean;
    CertFile     : string;   // caminho do cert PEM/PFX
    KeyFile      : string;   // caminho da chave PEM
    CertPassword : string;   // senha do PFX
    WSPort       : Integer;  // porta WS (0 = mesma porta do Horse)
    WSSPort      : Integer;  // porta WSS quando TLS habilitado (default: porta+1 ou 443)
  end;

  THorseWebSocketMiddleware = class;

  // ---------------------------------------------------------------------------
  // THorseWSConnection — conexão individual com ClientID
  // ---------------------------------------------------------------------------
  THorseWSConnection = class(TWebSocketServerConnection)
  private
    FUnregistered: Boolean;
  protected
    procedure AfterConnectionExecute; override;
  public
    ClientID: string;
    constructor Create(Socket: TTCPCustomConnectionSocket); override;
  end;

  // ---------------------------------------------------------------------------
  // THorseWSServerExt — servidor Bauglir customizado
  //
  // IMPORTANTE: O Bauglir original usa Synchronize() nos hooks - isso trava em
  // apps console. Sobrescrevemos DoAfterAddConnection para chamar os callbacks
  // DIRETAMENTE na thread do servidor (sem Synchronize).
  // ---------------------------------------------------------------------------
  THorseWSServerExt = class(WebSocket.Core.TWebSocketServer)
  private
    FMiddleware: THorseWebSocketMiddleware;
  protected
    function GetWebSocketConnectionClass(Socket: TTCPCustomConnectionSocket;
                                         Header: TStringList;
                                         ResourceName, Host, Port, Origin, Cookie: AnsiString;
                                         out HttpResult: Integer;
                                         var Protocol, Extensions: AnsiString): TWebSocketServerConnections; override;

    // Sobrescrito para NÃO usar Synchronize — funciona em apps console
    procedure DoAfterAddConnection; override;
  public
    constructor Create(AMiddleware: THorseWebSocketMiddleware; const APort: Integer);

    // Handlers 'of object' para conexões Bauglir
    procedure HandleConnectionReadFull(Sender: TWebSocketCustomConnection;
                                        OpCode: Byte; Data: TMemoryStream);
    procedure HandleConnectionClose(Sender: TWebSocketCustomConnection;
                                     CloseCode: Integer; CloseReason: AnsiString;
                                     ClosedByPeer: Boolean);
  end;

  // ---------------------------------------------------------------------------
  // THorseWebSocketMiddleware — classe central do middleware
  // ---------------------------------------------------------------------------
  THorseWebSocketMiddleware = class
  private
    FConfig    : THorseWebSocketConfig;
    FWSServer  : TWebSocketServer;    // nosso gerenciador de clientes
    FEIOMan    : TEngineIOManager;    // engine.io
    FSIOMan    : TSocketIOManager;    // socket.io

    // Servidor WebSocket RFC 6455 rodando em thread separada (Bauglir)
    FBiotServer  : THorseWSServerExt;
    FBiotPort    : Integer;

    class var FInstance: THorseWebSocketMiddleware;

    procedure SetupEngineIOCallbacks;
    procedure SetupSocketIOCallbacks;
    procedure StartBiotServer;

  public
    constructor Create;
    destructor  Destroy; override;

    class function  GetInstance: THorseWebSocketMiddleware;
    class procedure DestroyInstance;

    procedure Configure(const Config: THorseWebSocketConfig);

    // Retorna o middleware Horse (proc que será passado ao THorse.Use)
    function  GetMiddleware: THorseCallback;

    // Acesso ao gerenciador de clientes (para o dev usar externamente)
    function  Clients: TWebSocketServer;
    function  SocketIO: TSocketIOManager;

    property Config: THorseWebSocketConfig read FConfig;
  end;

// ============================================================================
// Funções públicas de conveniência
// ============================================================================

// Retorna o middleware para usar no THorse.Use()
function HorseWebSocket: THorseCallback; overload;
function HorseWebSocket(const Config: THorseWebSocketConfig): THorseCallback; overload;

// Acesso ao gerenciador de clientes WebSocket
function WSClients: THorseWSServer;

// Acesso ao Socket.IO
function SocketIO: TSocketIOManager;

// Acesso ao Engine.IO
function EngineIO: TEngineIOManager;

// Config padrão
function DefaultWSConfig: THorseWebSocketConfig;

implementation

uses
  SyncObjs, Generics.Collections
{$IFDEF MSWINDOWS}
  , Windows
{$ENDIF}
  ;

// ============================================================================
// Defaults
// ============================================================================

function DefaultWSConfig: THorseWebSocketConfig;
begin
  Result.WSPath        := '/ws';
  Result.EIOPath       := '/engine.io/';
  Result.SIOPath       := '/socket.io/';
  Result.AllowedOrigin := '*';
  Result.TLSEnabled    := False;
  Result.CertFile      := '';
  Result.KeyFile       := '';
  Result.CertPassword  := '';
  Result.WSPort        := 0;    // 0 = separado na porta 9001 (configurável)
  Result.WSSPort       := 0;
end;

// ============================================================================
// THorseWSConnection — Implementação
// ============================================================================

constructor THorseWSConnection.Create(Socket: TTCPCustomConnectionSocket);
begin
  inherited Create(Socket);
  FUnregistered := False;
  ClientID := '';
end;

procedure THorseWSConnection.AfterConnectionExecute;
begin
  // Garante unregister mesmo em desconexão abrupta (sem close frame)
  if (not FUnregistered) and (ClientID <> '') then
  begin
    FUnregistered := True;
    if (Parent is THorseWSServerExt) then
      THorseWSServerExt(Parent).FMiddleware.FWSServer.UnregisterClient(ClientID);
  end;
  inherited;
end;

// ============================================================================
// THorseWSServerExt — Implementação
// ============================================================================

constructor THorseWSServerExt.Create(AMiddleware: THorseWebSocketMiddleware; const APort: Integer);
begin
  inherited Create('0.0.0.0', IntToStr(APort));
  FMiddleware := AMiddleware;
end;

function THorseWSServerExt.GetWebSocketConnectionClass(
                                   Socket: TTCPCustomConnectionSocket;
                                   Header: TStringList;
                                   ResourceName, Host, Port, Origin, Cookie: AnsiString;
                                   out HttpResult: Integer;
                                   var Protocol, Extensions: AnsiString): TWebSocketServerConnections;
begin
  HttpResult := 101;
  // Não exigir extensões específicas — aceitar tudo
  Extensions := '-';
  Result := THorseWSConnection;
end;



procedure THorseWSServerExt.DoAfterAddConnection;
var
  Conn: THorseWSConnection;
  ClientID, RemoteIP, ResName, SIDParam: string;
  Sess: TEngineIOSessionObj;
  Proto: TWSProtocolMode;
begin
  // NÃO chamar inherited (que usa Synchronize).
  // Configuramos tudo diretamente aqui na thread do servidor.

  if not (FCurrentAddConnection is THorseWSConnection) then
    Exit;

  Conn := THorseWSConnection(FCurrentAddConnection);
  ResName := string(Conn.ResourceName);

  // Tenta extrair o SID do Engine.IO da query string do ResourceName
  // Ex: /socket.io/?EIO=4&transport=websocket&sid=XXXX
  SIDParam := GetQueryParam(ResName, 'sid');

  if SIDParam <> '' then
  begin
    // Conexão WS com SID existente (Engine.IO/Socket.IO upgrade)
    Sess := FMiddleware.FEIOMan.GetSession(SIDParam);
    if Assigned(Sess) then
    begin
      ClientID := SIDParam;
      Sess.Transport := eitWebSocket;
      Proto := wpmEngineIO;
    end
    else
    begin
      // SID não encontrado — fallback para WS puro
      ClientID := NewGUID;
      Proto := wpmRaw;
    end;
  end
  else if (Pos('/socket.io', ResName) > 0) or (Pos('/engine.io', ResName) > 0) then
  begin
    // Conexão Engine.IO direta via WS (sem SID de polling prévio)
    // Cria uma nova sessão Engine.IO
    Sess := FMiddleware.FEIOMan.CreateSession;
    ClientID := Sess.SID;
    Sess.Transport := eitWebSocket;
    Proto := wpmEngineIO;
    // Envia open packet via WS
    try
      Conn.SendText(AnsiString(FMiddleware.FEIOMan.BuildOpenPacket(ClientID)));
    except
    end;
  end
  else
  begin
    // WebSocket puro (JS nativo, ex: /ws)
    ClientID := NewGUID;
    Proto := wpmRaw;
  end;

  Conn.ClientID := ClientID;

  try
    RemoteIP := string(Conn.Socket.GetRemoteSinIP);
  except
    RemoteIP := '0.0.0.0';
  end;

  // Ativar FullDataProcess para receber mensagens completas via OnReadFull
  Conn.FullDataProcess := True;

  // Configurar callbacks 'of object' — apontam para métodos desta classe
  Conn.OnReadFull := HandleConnectionReadFull;
  Conn.OnClose := HandleConnectionClose;

  // Registrar o cliente no nosso mapa de clientes
  FMiddleware.FWSServer.RegisterClient(ClientID, TWebSocketServerConnection(Conn), Proto, RemoteIP);
end;

procedure THorseWSServerExt.HandleConnectionReadFull(
  Sender: TWebSocketCustomConnection;
  OpCode: Byte; Data: TMemoryStream);
var
  Conn: THorseWSConnection;
  Msg: string;
  Buf: TBytes;
  SS: TStringStream;
begin
  if not (Sender is THorseWSConnection) then
    Exit;

  Conn := THorseWSConnection(Sender);
  Data.Position := 0;

  case OpCode of
    wsCodeText:
    begin
      SS := TStringStream.Create('', TEncoding.UTF8);
      try
        SS.CopyFrom(Data, Data.Size);
        Msg := SS.DataString;
      finally
        SS.Free;
      end;

      // Detecta Engine.IO (começa com dígito EIO: '0'..'6')
      if (Length(Msg) > 0) and CharInSet(Msg[1], ['0'..'6']) then
        FMiddleware.FEIOMan.HandleWSMessage(Conn.ClientID, Msg)
      else
      begin
        // WebSocket puro (JS nativo)
        FMiddleware.FWSServer.HandleMessage(Conn.ClientID, Msg);
      end;
    end;

    wsCodeBinary:
    begin
      SetLength(Buf, Data.Size);
      if Data.Size > 0 then
        Data.ReadBuffer(Buf[0], Data.Size);
      FMiddleware.FWSServer.HandleBinary(Conn.ClientID, Buf);
    end;
  end;
end;

procedure THorseWSServerExt.HandleConnectionClose(
  Sender: TWebSocketCustomConnection;
  CloseCode: Integer; CloseReason: AnsiString; ClosedByPeer: Boolean);
var
  Conn: THorseWSConnection;
begin
  if not (Sender is THorseWSConnection) then
    Exit;

  Conn := THorseWSConnection(Sender);
  if (not Conn.FUnregistered) and (Conn.ClientID <> '') then
  begin
    Conn.FUnregistered := True;
    FMiddleware.FWSServer.UnregisterClient(Conn.ClientID);
  end;
end;

// ============================================================================
// THorseWebSocketMiddleware — Implementação
// ============================================================================

constructor THorseWebSocketMiddleware.Create;
begin
  inherited;
  FConfig   := DefaultWSConfig;
  FWSServer := THorseWSServer.Instance;
  FEIOMan   := TEngineIOManager.Instance;
  FSIOMan   := TSocketIOManager.Instance;
  FBiotServer := nil;
end;

destructor THorseWebSocketMiddleware.Destroy;
begin
  if Assigned(FBiotServer) then
  begin
    FBiotServer.CloseAllConnections(wsCloseShutdown, 'Server shutting down');
    FBiotServer.TerminateThread;
    FBiotServer.WaitFor;
    FBiotServer.Free;
    FBiotServer := nil;
  end;
  inherited;
end;

class function THorseWebSocketMiddleware.GetInstance: THorseWebSocketMiddleware;
begin
  if not Assigned(FInstance) then
    FInstance := THorseWebSocketMiddleware.Create;
  Result := FInstance;
end;

class procedure THorseWebSocketMiddleware.DestroyInstance;
begin
  FreeAndNil(FInstance);
end;

procedure THorseWebSocketMiddleware.Configure(const Config: THorseWebSocketConfig);
begin
  FConfig := Config;
end;

procedure THorseWebSocketMiddleware.SetupEngineIOCallbacks;
begin
  // Engine.IO → Socket.IO bridge
  FEIOMan.OnEIOConnect := procedure(const ClientID: string)
  begin
    // EIO conectou: Socket.IO vai receber o CONNECT packet via HandlePayload
  end;

  FEIOMan.OnEIODisconnect := procedure(const ClientID: string)
  begin
    FSIOMan.HandleDisconnect(ClientID);
    FWSServer.UnregisterClient(ClientID);
  end;

  FEIOMan.OnEIOMessage := procedure(const ClientID, Payload: string)
  begin
    // Payload = Socket.IO packet (sem o prefixo EIO '4')
    FSIOMan.HandlePayload(ClientID, Payload);
  end;

  // Injeta função de envio WS no Engine.IO (para heartbeat e respostas diretas)
  FEIOMan.SetSendWSFunction(
    procedure(SID, Packet: string)
    begin
      var Client := FWSServer.GetClient(SID);
      if Assigned(Client) and Client.IsConnected then
        Client.SendText(Packet);
    end
  );
end;

procedure THorseWebSocketMiddleware.SetupSocketIOCallbacks;
begin
  // Socket.IO precisa de uma função para enviar dados de volta ao cliente
  // Via WebSocket: envia frame de texto
  FSIOMan.SetSendFunction(
    procedure(ClientID, EIOPacket: string)
    begin
      var Client := FWSServer.GetClient(ClientID);
      if Assigned(Client) and Client.IsConnected then
        Client.SendText(EIOPacket)
      else
      begin
        // Fallback: via polling buffer
        var Sess := FEIOMan.GetSession(ClientID);
        if Assigned(Sess) then
          Sess.QueuePacket(EIOPacket);
      end;
    end
  );
end;

procedure THorseWebSocketMiddleware.StartBiotServer;
var
  Port: Integer;
begin
  if Assigned(FBiotServer) then Exit;

  // Determina porta WS separada
  Port := FConfig.WSPort;
  if Port = 0 then Port := 9001; // default

  FBiotPort := Port;
  FBiotServer := THorseWSServerExt.Create(Self, FBiotPort);
  FBiotServer.Start;

  //WriteLn('[WS] Servidor WebSocket iniciado na porta ', FBiotPort);
  SafeLog('[WS] Servidor WebSocket iniciado na porta ' + IntToStr(FBiotPort));
end;

function THorseWebSocketMiddleware.GetMiddleware: THorseCallback;
var
  Self2: THorseWebSocketMiddleware;
begin
  Self2 := Self;

  // Setup callbacks (idempotente)
  SetupEngineIOCallbacks;
  SetupSocketIOCallbacks;
  StartBiotServer;

  // Inicia timer de heartbeat Engine.IO (uma única vez)
  FEIOMan.StartHeartbeatTimer;

  Result :=
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TNextProc)
    var
      URL, EIOVer, Transport: string;
      IsWS, IsEIO: Boolean;
    begin
      URL := Req.RawWebRequest.PathInfo;
      if Req.RawWebRequest.Query <> '' then
        URL := URL + '?' + Req.RawWebRequest.Query;

      IsWS  := SameText(Req.Headers['upgrade'], 'websocket');
      IsEIO := StartsWithCI(Req.RawWebRequest.PathInfo, Self2.FConfig.EIOPath) or
               StartsWithCI(Req.RawWebRequest.PathInfo, Self2.FConfig.SIOPath) or
               StartsWithCI(Req.RawWebRequest.PathInfo, '/engine.io') or
               StartsWithCI(Req.RawWebRequest.PathInfo, '/socket.io');

      if IsEIO then
      begin
        // Engine.IO / Socket.IO request
        Req.Query.TryGetValue('EIO', EIOVer);
        Req.Query.TryGetValue('transport', Transport);

        // CORS preflight
        if SameText(Req.RawWebRequest.Method, 'OPTIONS') then
        begin
          Res.AddHeader('Access-Control-Allow-Origin',  Self2.FConfig.AllowedOrigin);
          Res.AddHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
          Res.AddHeader('Access-Control-Allow-Headers', 'Content-Type');
          Res.Status(204).Send('');
          raise EHorseCallbackInterrupted.Create;
        end;

        Res.AddHeader('Access-Control-Allow-Origin', Self2.FConfig.AllowedOrigin);

        if SameText(Transport, 'polling') then
        begin
          if SameText(Req.RawWebRequest.Method, 'POST') then
            Self2.FEIOMan.HandlePollingPOST(Req, Res)
          else
            Self2.FEIOMan.HandlePollingGET(Req, Res);
          
          raise EHorseCallbackInterrupted.Create;
        end
        else if SameText(Transport, 'websocket') then
        begin
          // Socket.IO tentou upgrade WS na porta HTTP — não suportado pelo Indy.
          // Retornar erro para que o cliente fique no polling.
          Res.Status(400).Send('{"code":3,"message":"Transport not available"}');
          raise EHorseCallbackInterrupted.Create;
        end;
      end;

      // Rota informativa sobre a porta WS
      if StartsWithCI(URL, Self2.FConfig.WSPath) and not IsWS then
      begin
        Res.Status(200).Send(Format(
          '{"websocket_port":%d,"protocol":"ws"}', [Self2.FBiotPort]));
        Exit;
      end;

      // Passa para o próximo handler Horse
      Next();
    end;
end;

function THorseWebSocketMiddleware.Clients: TWebSocketServer;
begin
  Result := FWSServer;
end;

function THorseWebSocketMiddleware.SocketIO: TSocketIOManager;
begin
  Result := FSIOMan;
end;

// ============================================================================
// Funções públicas
// ============================================================================

function HorseWebSocket: THorseCallback;
begin
  Result := THorseWebSocketMiddleware.GetInstance.GetMiddleware();
end;

function HorseWebSocket(const Config: THorseWebSocketConfig): THorseCallback;
begin
  THorseWebSocketMiddleware.GetInstance.Configure(Config);
  Result := THorseWebSocketMiddleware.GetInstance.GetMiddleware();
end;

function WSClients: THorseWSServer;
begin
  Result := THorseWSServer.Instance;
end;

function SocketIO: TSocketIOManager;
begin
  Result := TSocketIOManager.Instance;
end;

function EngineIO: TEngineIOManager;
begin
  Result := TEngineIOManager.Instance;
end;

initialization
finalization
  THorseWebSocketMiddleware.DestroyInstance;

end.
