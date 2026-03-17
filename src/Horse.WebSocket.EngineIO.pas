// ============================================================================
// Horse.WebSocket.EngineIO.pas
// Implementação do protocolo Engine.IO v4
//
// Responsabilidades:
//   - Rota /engine.io/ (polling e websocket)
//   - Handshake de sessão (open packet + SID)
//   - Transporte HTTP long-polling
//   - Upgrade polling → WebSocket
//   - Heartbeat (ping/pong)
// ============================================================================

unit Horse.WebSocket.EngineIO;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Generics.Collections,
  Horse,
  Horse.WebSocket.Types,
  Horse.WebSocket.Utils;

type
  // ---------------------------------------------------------------------------
  // Forward declarations
  // ---------------------------------------------------------------------------
  TEngineIOManager = class;

  // ---------------------------------------------------------------------------
  // TEngineIOSessionObj — estado completo de uma sessão Engine.IO
  // ---------------------------------------------------------------------------
  TEngineIOSessionObj = class
  public
    SID             : string;
    Transport       : TEngineIOTransport;   // eitPolling ou eitWebSocket
    LastPingTime    : Int64;                // tick em ms (última resposta pong recebida)
    LastPingSent    : Int64;                // tick em ms (último ping enviado pelo servidor)
    PollBuffer      : TStringList;          // pacotes pendentes para polling
    PollBufferLock  : TCriticalSection;
    Connected       : Boolean;
    NamespacePath   : string;              // ex: '/'
    constructor Create(const ASID: string);
    destructor  Destroy; override;
    procedure   QueuePacket(const Pkt: string);
    function    DrainPackets: string;       // flush para resposta polling
  end;

  // ---------------------------------------------------------------------------
  // TEngineIOManager — gerencia sessões Engine.IO
  // ---------------------------------------------------------------------------
  TEngineIOManager = class
  private
    FSessions    : TDictionary<string, TEngineIOSessionObj>;
    FLock        : TCriticalSection;

    // Callbacks para camada Socket.IO
    FOnEIOConnect    : TWSOnConnect;
    FOnEIODisconnect : TWSOnDisconnect;
    FOnEIOMessage    : TWSOnMessage;   // dados "4<socketio_payload>"

    // Função para enviar frames WS diretamente (injetada pelo middleware)
    FSendWSFn : TProc<string, string>;  // FSendWSFn(SID, Packet)

    // Controle do heartbeat
    FHeartbeatStarted : Boolean;
    FHeartbeatStop    : Boolean;

    class var FInstance: TEngineIOManager;
  public
    constructor Create;
    destructor  Destroy; override;

    class function  Instance: TEngineIOManager;
    class procedure DestroyInstance;

    // Injetar função de envio WS (chamada pelo middleware)
    procedure SetSendWSFunction(Fn: TProc<string, string>);

    // Criação / destruição de sessões
    function  CreateSession: TEngineIOSessionObj;
    function  GetSession(const SID: string): TEngineIOSessionObj;
    procedure RemoveSession(const SID: string);

    // Processamento de requisições HTTP (polling)
    procedure HandlePollingGET(Req: THorseRequest; Res: THorseResponse);
    procedure HandlePollingPOST(Req: THorseRequest; Res: THorseResponse);

    // Processamento de frame WebSocket recebido (chamado pelo middleware principal)
    procedure HandleWSMessage(const SID, AData: string);
    procedure HandleWSClose(const SID: string);

    // Constrói o open packet JSON para enviar ao cliente
    function BuildOpenPacket(const SID: string): string;

    // Envia um pacote Engine.IO para um cliente específico via polling buffer
    procedure SendToSession(const SID, Packet: string);

    // Inicia o timer de heartbeat (chamado uma vez pelo middleware)
    procedure StartHeartbeatTimer;

    // Para o timer de heartbeat (permite reinício posterior)
    procedure StopHeartbeatTimer;

    // Limpa todas as sessões ativas (sem disparar callbacks)
    procedure ClearSessions;

    // Callbacks
    property OnEIOConnect    : TWSOnConnect    read FOnEIOConnect    write FOnEIOConnect;
    property OnEIODisconnect : TWSOnDisconnect read FOnEIODisconnect write FOnEIODisconnect;
    property OnEIOMessage    : TWSOnMessage    read FOnEIOMessage    write FOnEIOMessage;
  end;

implementation

// ============================================================================
// TEngineIOSessionObj
// ============================================================================

constructor TEngineIOSessionObj.Create(const ASID: string);
begin
  inherited Create;
  SID            := ASID;
  Transport      := eitPolling;
  LastPingTime   := GetTickCount64MS;
  LastPingSent   := GetTickCount64MS;
  PollBuffer     := TStringList.Create;
  PollBufferLock := TCriticalSection.Create;
  Connected      := True;
  NamespacePath  := '/';
end;

destructor TEngineIOSessionObj.Destroy;
begin
  PollBuffer.Free;
  PollBufferLock.Free;
  inherited;
end;

procedure TEngineIOSessionObj.QueuePacket(const Pkt: string);
begin
  PollBufferLock.Enter;
  try
    PollBuffer.Add(Pkt);
  finally
    PollBufferLock.Leave;
  end;
end;

function TEngineIOSessionObj.DrainPackets: string;
var
  I: Integer;
begin
  PollBufferLock.Enter;
  try
    if PollBuffer.Count = 0 then
    begin
      // Keep-alive noop
      Result := EIO_NOOP;
      Exit;
    end;

    // Engine.IO polling: múltiplos pacotes separados por chr(30) (RS)
    Result := '';
    for I := 0 to PollBuffer.Count - 1 do
    begin
      if I > 0 then
        Result := Result + #30;   // Record Separator (RFC 7159 / Engine.IO spec)
      Result := Result + PollBuffer[I];
    end;
    PollBuffer.Clear;
  finally
    PollBufferLock.Leave;
  end;
end;

// ============================================================================
// TEngineIOManager
// ============================================================================


constructor TEngineIOManager.Create;
begin
  inherited;
  FSessions := TDictionary<string, TEngineIOSessionObj>.Create;
  FLock     := TCriticalSection.Create;
  FHeartbeatStarted := False;
  FHeartbeatStop    := False;
end;

destructor TEngineIOManager.Destroy;
begin
  StopHeartbeatTimer;
  ClearSessions;
  FSessions.Free;
  FLock.Free;
  inherited;
end;

procedure TEngineIOManager.StopHeartbeatTimer;
begin
  if not FHeartbeatStarted then Exit;
  FHeartbeatStop := True;
  Sleep(150); // espera a thread de heartbeat perceber o stop
  FHeartbeatStarted := False;
end;

procedure TEngineIOManager.ClearSessions;
var
  Pair: TPair<string, TEngineIOSessionObj>;
begin
  FLock.Enter;
  try
    for Pair in FSessions do
      Pair.Value.Free;
    FSessions.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TEngineIOManager.SetSendWSFunction(Fn: TProc<string, string>);
begin
  FSendWSFn := Fn;
end;

class function TEngineIOManager.Instance: TEngineIOManager;
begin
  if not Assigned(FInstance) then
    FInstance := TEngineIOManager.Create;
  Result := FInstance;
end;

class procedure TEngineIOManager.DestroyInstance;
begin
  FreeAndNil(FInstance);
end;

function TEngineIOManager.CreateSession: TEngineIOSessionObj;
var
  SID: string;
  Sess: TEngineIOSessionObj;
begin
  SID  := GenerateSessionID;
  Sess := TEngineIOSessionObj.Create(SID);
  FLock.Enter;
  try
    FSessions.Add(SID, Sess);
  finally
    FLock.Leave;
  end;
  Result := Sess;
end;

function TEngineIOManager.GetSession(const SID: string): TEngineIOSessionObj;
begin
  FLock.Enter;
  try
    if not FSessions.TryGetValue(SID, Result) then
      Result := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TEngineIOManager.RemoveSession(const SID: string);
var
  Sess: TEngineIOSessionObj;
begin
  FLock.Enter;
  try
    if FSessions.TryGetValue(SID, Sess) then
    begin
      FSessions.Remove(SID);
      Sess.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TEngineIOManager.BuildOpenPacket(const SID: string): string;
begin
  // EIO_OPEN = '0', seguido do JSON da sessão
  // Não anunciar upgrades WS — Horse (Indy) não suporta WS upgrade na mesma porta
  // O Socket.IO permanece em HTTP long-polling, que é totalmente funcional e estável.
  Result := EIO_OPEN +
    Format('{"sid":"%s","upgrades":[],"pingInterval":%d,"pingTimeout":%d,"maxPayload":%d}',
      [SID, EIO_PING_INTERVAL, EIO_PING_TIMEOUT, EIO_MAX_PAYLOAD]);
end;

procedure TEngineIOManager.SendToSession(const SID, Packet: string);
var
  Sess: TEngineIOSessionObj;
begin
  Sess := GetSession(SID);
  if Assigned(Sess) then
    Sess.QueuePacket(Packet);
end;

// ---------------------------------------------------------------------------
// StartHeartbeatTimer — Inicia thread que envia pings periódicos
// Engine.IO v4: SERVIDOR envia ping ('2'), CLIENTE responde pong ('3')
// ---------------------------------------------------------------------------
procedure TEngineIOManager.StartHeartbeatTimer;
var
  Manager: TEngineIOManager;
begin
  if FHeartbeatStarted then Exit;
  FHeartbeatStarted := True;
  FHeartbeatStop    := False;   // garante que a flag está limpa (importante no restart)
  Manager := Self;

  TThread.CreateAnonymousThread(
    procedure
    var
      SIDs: TArray<string>;
      SID: string;
      Sess: TEngineIOSessionObj;
      Now_: Int64;
      StaleSIDs: TList<string>;
      I: Integer;
      Pair: TPair<string, TEngineIOSessionObj>;
    begin
      while not Manager.FHeartbeatStop do
      begin
        Sleep(EIO_PING_INTERVAL);
        if Manager.FHeartbeatStop then Break;

        Now_ := GetTickCount64MS;
        StaleSIDs := TList<string>.Create;
        try
          // Coleta SIDs
          Manager.FLock.Enter;
          try
            SetLength(SIDs, Manager.FSessions.Count);
            I := 0;
            for Pair in Manager.FSessions do
            begin
              SIDs[I] := Pair.Key;
              Inc(I);
            end;
          finally
            Manager.FLock.Leave;
          end;

          // Itera cada sessão
          for SID in SIDs do
          begin
            if Manager.FHeartbeatStop then Break;

            Sess := Manager.GetSession(SID);
            if not Assigned(Sess) then Continue;
            if not Sess.Connected then
            begin
              StaleSIDs.Add(SID);
              Continue;
            end;

            // Verifica timeout: se o último pong recebido foi há muito tempo
            if (Now_ - Sess.LastPingTime) > Int64(EIO_PING_INTERVAL + EIO_PING_TIMEOUT + 5000) then
            begin
              StaleSIDs.Add(SID);
              Continue;
            end;

            // Envia EIO PING para o cliente
            if Sess.Transport = eitWebSocket then
            begin
              if Assigned(Manager.FSendWSFn) then
              begin
                try
                  Manager.FSendWSFn(SID, EIO_PING);
                except
                end;
              end;
            end
            else
            begin
              // Polling: enfileira o ping para ser entregue no próximo GET
              Sess.QueuePacket(EIO_PING);
            end;

            Sess.LastPingSent := Now_;
          end;

          // Remove sessões expiradas
          for SID in StaleSIDs do
          begin
            if Manager.FHeartbeatStop then Break;
            try
              if Assigned(Manager.FOnEIODisconnect) then
                Manager.FOnEIODisconnect(SID);
            except
            end;
            Manager.RemoveSession(SID);
          end;
        finally
          StaleSIDs.Free;
        end;
      end;
    end
  ).Start;
end;

// ---------------------------------------------------------------------------
// HandlePollingGET
// GET /engine.io/?EIO=4&transport=polling[&sid=xxx]
// ---------------------------------------------------------------------------
procedure TEngineIOManager.HandlePollingGET(Req: THorseRequest; Res: THorseResponse);
var
  SID, Transport: string;
  Sess: TEngineIOSessionObj;
  ResponseBody: string;
begin
  // Usa Req.Query (TDictionary de strings do Horse) para extrair os parâmetros com segurança
  Req.Query.TryGetValue('sid', SID);
  Req.Query.TryGetValue('transport', Transport);

  Res.AddHeader('Content-Type', 'text/plain; charset=UTF-8');
  Res.AddHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  Res.AddHeader('Pragma', 'no-cache');
  Res.AddHeader('Access-Control-Allow-Origin', '*');
  Res.AddHeader('Access-Control-Allow-Credentials', 'true');

  if SID = '' then
  begin
    // Nova sessão
    Sess := CreateSession;
    ResponseBody := BuildOpenPacket(Sess.SID);
    if Assigned(FOnEIOConnect) then
      FOnEIOConnect(Sess.SID);
  end
  else
  begin
    Sess := GetSession(SID);
    if not Assigned(Sess) then
    begin
      Res.Status(400).Send('{"code":1,"message":"Session ID unknown"}');
      Exit;
    end;
    // Atualiza para indicar que o cliente está ativo (polling = keep-alive implícito)
    Sess.LastPingTime := GetTickCount64MS;
    // Retorna pacotes pendentes (long-poll)
    ResponseBody := Sess.DrainPackets;
  end;

  Res.Status(200).Send(ResponseBody);
end;

// ---------------------------------------------------------------------------
// HandlePollingPOST
// POST /engine.io/?EIO=4&transport=polling&sid=xxx
// Body = pacote(s) Engine.IO vindos do cliente
// ---------------------------------------------------------------------------
procedure TEngineIOManager.HandlePollingPOST(Req: THorseRequest; Res: THorseResponse);
var
  SID, Body, PacketType, Payload: string;
  Sess: TEngineIOSessionObj;
  Parts: TArray<string>;
  Part: string;
begin
  Res.AddHeader('Content-Type', 'text/html');
  Res.AddHeader('Access-Control-Allow-Origin', '*');
  Res.AddHeader('Access-Control-Allow-Credentials', 'true');

  Req.Query.TryGetValue('sid', SID);
  if SID = '' then
  begin
    Res.Status(400).Send('Missing sid');
    Exit;
  end;

  Sess := GetSession(SID);
  if not Assigned(Sess) then
  begin
    Res.Status(400).Send('Session not found');
    Exit;
  end;

  Body := Req.RawWebRequest.Content;

  // Pacotes separados por chr(30) (multi-packet)
  Parts := Body.Split([#30]);
  for Part in Parts do
  begin
    if Length(Part) = 0 then Continue;
    PacketType := Copy(Part, 1, 1);
    Payload    := Copy(Part, 2, MaxInt);

    case PacketType[1] of
      '2': // PING do cliente (probe ou heartbeat de polling)
        begin
          Sess.LastPingTime := GetTickCount64MS;
          Sess.QueuePacket(EIO_PONG + Payload);
        end;
      '3': // PONG — resposta do cliente ao ping do servidor
        begin
          Sess.LastPingTime := GetTickCount64MS;
        end;
      '1': // CLOSE
        begin
          Sess.Connected := False;
          if Assigned(FOnEIODisconnect) then
            FOnEIODisconnect(SID);
          RemoveSession(SID);
        end;
      '4': // MESSAGE (Socket.IO payload)
        begin
          Sess.LastPingTime := GetTickCount64MS;
          if Assigned(FOnEIOMessage) then
            FOnEIOMessage(SID, Payload);
        end;
    end;
  end;

  Res.Status(200).Send('ok');
end;

// ---------------------------------------------------------------------------
// HandleWSMessage — chamado pelo middleware ao receber frame WS de um cliente
// com sessão Engine.IO ativa
// ---------------------------------------------------------------------------
procedure TEngineIOManager.HandleWSMessage(const SID, AData: string);
var
  PacketType, Payload: string;
  Sess: TEngineIOSessionObj;
begin
  Sess := GetSession(SID);
  if not Assigned(Sess) then Exit;

  if Length(AData) = 0 then Exit;
  PacketType := AData[1];
  Payload    := Copy(AData, 2, MaxInt);

  case PacketType[1] of
    '2': // PING do cliente — probe de upgrade ou heartbeat
      begin
        if Payload = 'probe' then
        begin
          // Upgrade probe: responder "3probe" via WS direto
          if Assigned(FSendWSFn) then
          begin
            try
              FSendWSFn(SID, EIO_PONG + 'probe');
            except
            end;
          end
          else
            Sess.QueuePacket(EIO_PONG + 'probe');
        end
        else
        begin
          // Heartbeat ping do cliente — responder pong
          Sess.LastPingTime := GetTickCount64MS;
          if Assigned(FSendWSFn) then
          begin
            try
              FSendWSFn(SID, EIO_PONG);
            except
            end;
          end
          else
            Sess.QueuePacket(EIO_PONG);
        end;
      end;
    '3': // PONG — resposta do cliente ao ping do servidor (heartbeat)
      begin
        Sess.LastPingTime := GetTickCount64MS;
      end;
    '5': // UPGRADE confirmado pelo cliente
      begin
        Sess.Transport := eitWebSocket;
      end;
    '1': // CLOSE
      begin
        Sess.Connected := False;
        if Assigned(FOnEIODisconnect) then
          FOnEIODisconnect(SID);
        RemoveSession(SID);
      end;
    '4': // MESSAGE → Socket.IO payload
      begin
        Sess.LastPingTime := GetTickCount64MS;
        if Assigned(FOnEIOMessage) then
          FOnEIOMessage(SID, Payload);
      end;
  end;
end;

procedure TEngineIOManager.HandleWSClose(const SID: string);
begin
  if Assigned(FOnEIODisconnect) then
    FOnEIODisconnect(SID);
  RemoveSession(SID);
end;

initialization
finalization
  TEngineIOManager.DestroyInstance;

end.
