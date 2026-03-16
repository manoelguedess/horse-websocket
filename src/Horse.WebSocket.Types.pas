// ============================================================================
// Horse.WebSocket.Types.pas
// Tipos compartilhados do middleware Horse-WebSocket
// ============================================================================
// Compatível com Delphi D10.3+ e Lazarus/FPC
// ============================================================================

unit Horse.WebSocket.Types;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections;

type
  // ---------------------------------------------------------------------------
  // ID único de cada cliente WebSocket
  // ---------------------------------------------------------------------------
  TWSClientID = string;

  // ---------------------------------------------------------------------------
  // Tipos de eventos do servidor WebSocket
  // ---------------------------------------------------------------------------
  TWSOnConnect    = reference to procedure(const ClientID: TWSClientID);
  TWSOnDisconnect = reference to procedure(const ClientID: TWSClientID);
  TWSOnMessage    = reference to procedure(const ClientID: TWSClientID; const Data: string);
  TWSOnBinary     = reference to procedure(const ClientID: TWSClientID; const Data: TBytes);
  TWSOnError      = reference to procedure(const ClientID: TWSClientID; const E: Exception);

  // ---------------------------------------------------------------------------
  // Protocolo em uso pelo cliente
  // ---------------------------------------------------------------------------
  TWSProtocolMode = (
    wpmRaw,       // WebSocket puro RFC 6455 (JS nativo do browser)
    wpmEngineIO,  // Engine.IO v4 sobre WebSocket
    wpmSocketIO   // Socket.IO v5 (usa Engine.IO como transporte)
  );

  // ---------------------------------------------------------------------------
  // Estado de sessão Engine.IO
  // ---------------------------------------------------------------------------
  TEngineIOTransport = (eitPolling, eitWebSocket);

  TEngineIOSession = record
    SID          : string;              // session id único
    Transport    : TEngineIOTransport;  // transporte atual
    LastPing     : TDateTime;           // para timeout de heartbeat
    PollData     : string;              // dados pendentes para polling
    Connected    : Boolean;
  end;

  // ---------------------------------------------------------------------------
  // Interface de acesso a um cliente conectado
  // ---------------------------------------------------------------------------
  IWSClient = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    function  GetID: TWSClientID;
    function  GetProtocol: TWSProtocolMode;
    function  GetRemoteIP: string;
    function  IsConnected: Boolean;
    procedure SendText(const Msg: string);
    procedure SendBinary(const Data: TBytes);
    procedure SendBinaryStream(const Data: TStream);
    procedure Ping(const Data: string); // Keep-Alive nativo
    procedure Close;
    property ID       : TWSClientID    read GetID;
    property Protocol : TWSProtocolMode read GetProtocol;
    property RemoteIP : string          read GetRemoteIP;
  end;

  // ---------------------------------------------------------------------------
  // Constantes de Engine.IO v4
  // ---------------------------------------------------------------------------
const
  // Packet types Engine.IO v4
  EIO_OPEN    = '0';
  EIO_CLOSE   = '1';
  EIO_PING    = '2';
  EIO_PONG    = '3';
  EIO_MESSAGE = '4';
  EIO_UPGRADE = '5';
  EIO_NOOP    = '6';

  // Packet types Socket.IO v5
  SIO_CONNECT       = '0';
  SIO_DISCONNECT    = '1';
  SIO_EVENT         = '2';
  SIO_ACK           = '3';
  SIO_CONNECT_ERROR = '4';
  SIO_BINARY_EVENT  = '5';
  SIO_BINARY_ACK    = '6';

  // Heartbeat (ms)
  EIO_PING_INTERVAL = 25000;
  EIO_PING_TIMEOUT  = 20000;
  EIO_MAX_PAYLOAD   = 1000000;

  // Versão do Engine.IO suportada
  EIO_VERSION = '4';

  // Path padrão Engine.IO
  EIO_DEFAULT_PATH = '/engine.io/';
  SIO_DEFAULT_PATH = '/socket.io/';

implementation

end.
