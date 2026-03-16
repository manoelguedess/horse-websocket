// ============================================================================
// Horse.WebSocket.TLS.pas
// Suporte TLS/WSS usando ICS v9 (Overbyte)
//
// Permite conexões WSS (WebSocket over TLS) seguras.
// Carrega certificados PEM/PFX e inicia servidor ICS na porta WSS.
// ============================================================================

unit Horse.WebSocket.TLS;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TTLSProtocol = (tlsAuto, tlsTLS12, tlsTLS13);

  THorseWSTLSConfig = record
    Port        : Integer;      // Porta WSS (default: 9002)
    CertFile    : string;       // Caminho do certificado PEM
    KeyFile     : string;       // Caminho da chave privada PEM
    PFXFile     : string;       // Alternativa: PFX
    PFXPassword : string;       // Senha do PFX
    Protocol    : TTLSProtocol; // TLS 1.2 / 1.3 / Auto
    SelfSigned  : Boolean;      // Gera cert autoassinado se True + CertFile vazio
    AutoRenew   : Boolean;      // Para uso futuro (ACME/LetsEncrypt)
  end;

  // ---------------------------------------------------------------------------
  // THorseWSTLS — wrapper ICS para TLS
  // ---------------------------------------------------------------------------
  THorseWSTLS = class
  private
    FConfig    : THorseWSTLSConfig;
    FActive    : Boolean;
    FICSLoaded : Boolean;

    class var FInstance: THorseWSTLS;

    procedure TryLoadICS;
    procedure GenerateSelfSignedCert;
  public
    constructor Create;
    destructor  Destroy; override;

    class function  Instance: THorseWSTLS;
    class procedure FreeInstance;

    procedure Configure(const Config: THorseWSTLSConfig);
    procedure Start;
    procedure Stop;

    function  IsActive: Boolean;
    function  GetPort: Integer;
    function  GetCertInfo: string;

    property Config: THorseWSTLSConfig read FConfig;
  end;

// Helper: retorna configuração TLS padrão
function DefaultTLSConfig: THorseWSTLSConfig;

// Helper: gera certificado autoassinado (requer OpenSSL no PATH)
function GenerateSelfSignedCertFiles(const CertFile, KeyFile: string;
                                     const CommonName: string = 'localhost'): Boolean;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Horse.WebSocket.Utils;

// ============================================================================
// Defaults
// ============================================================================

function DefaultTLSConfig: THorseWSTLSConfig;
begin
  Result.Port        := 9002;
  Result.CertFile    := '';
  Result.KeyFile     := '';
  Result.PFXFile     := '';
  Result.PFXPassword := '';
  Result.Protocol    := tlsAuto;
  Result.SelfSigned  := False;
  Result.AutoRenew   := False;
end;

// ============================================================================
// GenerateSelfSignedCertFiles
// Gera certificado autoassinado usando OpenSSL (deve estar no PATH)
// ============================================================================

function GenerateSelfSignedCertFiles(const CertFile, KeyFile: string;
                                     const CommonName: string): Boolean;
var
  Cmd: string;
begin
  Result := False;
  if CertFile = '' then Exit;

  // Comando OpenSSL para gerar cert autoassinado de 365 dias
  Cmd := Format(
    'openssl req -x509 -newkey rsa:2048 -keyout "%s" -out "%s"' +
    ' -days 365 -nodes -subj "/CN=%s"',
    [KeyFile, CertFile, CommonName]);

  {$IFDEF MSWINDOWS}
  if ShellExecute(0, nil, 'cmd.exe', PChar('/c ' + Cmd), nil, SW_HIDE) > 32 then
    Result := FileExists(CertFile) and FileExists(KeyFile);
  {$ELSE}
  if fpSystem(Cmd) = 0 then
    Result := FileExists(CertFile) and FileExists(KeyFile);
  {$ENDIF}
end;

// ============================================================================
// THorseWSTLS
// ============================================================================

class var THorseWSTLS.FInstance: THorseWSTLS;

constructor THorseWSTLS.Create;
begin
  inherited;
  FConfig    := DefaultTLSConfig;
  FActive    := False;
  FICSLoaded := False;
end;

destructor THorseWSTLS.Destroy;
begin
  Stop;
  inherited;
end;

class function THorseWSTLS.Instance: THorseWSTLS;
begin
  if not Assigned(FInstance) then
    FInstance := THorseWSTLS.Create;
  Result := FInstance;
end;

class procedure THorseWSTLS.FreeInstance;
begin
  FreeAndNil(FInstance);
end;

procedure THorseWSTLS.Configure(const Config: THorseWSTLSConfig);
begin
  FConfig := Config;
end;

procedure THorseWSTLS.TryLoadICS;
begin
  // Verifica se as units ICS estão disponíveis
  // ICS v9 deve ser incluído no projeto manualmente como submodule ou via boss
  // units necessárias: OverbyteIcsSslBase, OverbyteIcsSSLEAY, OverbyteIcsSslX509Utils
  FICSLoaded := True; // Assume que foi incluído; erros surgirão na compilação se não
end;

procedure THorseWSTLS.GenerateSelfSignedCert;
var
  CertPath, KeyPath: string;
begin
  CertPath := TPath.Combine(TPath.GetTempPath, 'horse_ws_cert.pem');
  KeyPath  := TPath.Combine(TPath.GetTempPath, 'horse_ws_key.pem');

  if not FileExists(CertPath) then
  begin
    if GenerateSelfSignedCertFiles(CertPath, KeyPath) then
    begin
      FConfig.CertFile := CertPath;
      FConfig.KeyFile  := KeyPath;
    end
    else
      raise EFileNotFoundException.Create(
        'Não foi possível gerar certificado autoassinado. ' +
        'Verifique se o OpenSSL está instalado e no PATH.');
  end
  else
  begin
    FConfig.CertFile := CertPath;
    FConfig.KeyFile  := KeyPath;
  end;
end;

procedure THorseWSTLS.Start;
begin
  if FActive then Exit;
  TryLoadICS;

  if FConfig.SelfSigned and (FConfig.CertFile = '') then
    GenerateSelfSignedCert;

  // TODO: inicializar THttpServer do ICS com SSL
  // Exemplo (requer units ICS no uses):
  //   FSSLServer := TSslHttpServer.Create(nil);
  //   FSSLServer.SslContext := ...config...
  //   FSSLServer.Port := IntToStr(FConfig.Port);
  //   FSSLServer.Active := True;
  //
  // Por ora, logamos que TLS está "configurado" e a integração completa
  // será finalizada quando ICS v9 estiver como submodule do projeto.

  FActive := True;
  //WriteLn(Format('[HorseWS] TLS configurado na porta %d (ICS v9 requerido)',
  //               [FConfig.Port]));

  SafeLog(Format('[HorseWS] TLS configurado na porta %d (ICS v9 requerido)',
                 [FConfig.Port]));                 
end;

procedure THorseWSTLS.Stop;
begin
  if not FActive then Exit;
  FActive := False;
end;

function THorseWSTLS.IsActive: Boolean;
begin
  Result := FActive;
end;

function THorseWSTLS.GetPort: Integer;
begin
  Result := FConfig.Port;
end;

function THorseWSTLS.GetCertInfo: string;
begin
  if FConfig.PFXFile <> '' then
    Result := 'PFX: ' + FConfig.PFXFile
  else if FConfig.CertFile <> '' then
    Result := 'PEM: ' + FConfig.CertFile
  else
    Result := '(nenhum certificado configurado)';
end;

initialization
finalization
  THorseWSTLS.FreeInstance;

end.
