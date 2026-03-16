// ============================================================================
// Horse.WebSocket.Utils.pas
// Utilitários internos: GUID, SHA1, Base64, etc.
// ============================================================================

unit Horse.WebSocket.Utils;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  /// <summary>
  ///   Callback de notificação de log.
  ///   Atribua para redirecionar as mensagens internas (ex: para um TMemo em VCL).
  /// </summary>
  TWSLogNotify = reference to procedure(const Msg: string);

/// <summary>
///   Escreve uma mensagem de log de forma segura.
///   - Se OnWSLog estiver atribuído, chama o callback.
///   - Senão, se houver console (System.IsConsole), usa WriteLn.
///   - Senão, usa OutputDebugString (visível no Event Log do IDE).
/// </summary>
procedure SafeLog(const Msg: string);

// Gera um ID único de sessão (16 chars alfanuméricos)
function GenerateSessionID: string;

// Gera um GUID como string (sem chaves)
function NewGUID: string;

// SHA1 + Base64 para Sec-WebSocket-Accept
function ComputeWebSocketAccept(const Key: string): string;

// Encode/Decode Base64
function Base64Encode(const Data: TBytes): string; overload;
function Base64Encode(const Data: AnsiString): string; overload;

// Verifica se uma string começa com um prefixo (case-insensitive)
function StartsWithCI(const S, Prefix: string): Boolean;

// Obtém o caminho sem query string
function ExtractPath(const URL: string): string;

// Obtém o valor de um parâmetro da query string
function GetQueryParam(const URL, ParamName: string): string;

// Timestamp em milissegundos (para heartbeat)
function GetTickCount64MS: Int64;

var
  /// <summary>
  ///   Callback global de log. Atribua para capturar todas as mensagens
  ///   internas do Horse-WebSocket.
  ///   Exemplo VCL:
  ///     OnWSLog := procedure(const Msg: string)
  ///       begin
  ///         TThread.Queue(nil, procedure begin Memo1.Lines.Add(Msg) end);
  ///       end;
  /// </summary>
  OnWSLog: TWSLogNotify;

implementation

uses
  {$IFDEF FPC}
  sha1, base64
  {$ELSE}
  System.Hash, System.NetEncoding, StrUtils, Windows
  {$ENDIF}
  ;

procedure SafeLog(const Msg: string);
begin
  if Assigned(OnWSLog) then
    OnWSLog(Msg)
  else if System.IsConsole then
  begin
    try
      WriteLn(Msg);
    except
      // silencia I/O errors
    end;
  end
  {$IFDEF MSWINDOWS}
  else
    OutputDebugString(PChar(Msg));
  {$ENDIF}
end;

function NewGUID: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := GUIDToString(G);
  Result := Copy(Result, 2, Length(Result) - 2);
end;

function GenerateSessionID: string;
const
  Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
var
  G: TGUID;
  Raw: TBytes;
  I: Integer;
begin
  CreateGUID(G);
  SetLength(Raw, 16);
  Move(G.D1, Raw[0], 4);
  Move(G.D2, Raw[4], 2);
  Move(G.D3, Raw[6], 2);
  Move(G.D4[0], Raw[8], 8);
  Result := '';
  for I := 0 to 15 do
    Result := Result + Chars[(Raw[I] mod 64) + 1];
end;

function Base64Encode(const Data: TBytes): string;
begin
  {$IFDEF FPC}
  Result := string(EncodeStringBase64(string(Data)));
  {$ELSE}
  Result := TNetEncoding.Base64.EncodeBytesToString(Data);
  {$ENDIF}
end;

function Base64Encode(const Data: AnsiString): string;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, Length(Data));
  if Length(Data) > 0 then
    Move(Data[1], Bytes[0], Length(Data));
  Result := Base64Encode(Bytes);
end;

function ComputeWebSocketAccept(const Key: string): string;
const
  WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
var
  Combined: AnsiString;
  {$IFDEF FPC}
  SHA1Ctx: TSHA1Context;
  Digest: TSHA1Digest;
  DigestBytes: TBytes;
  I: Integer;
  {$ELSE}
  HashBytes: TBytes;
  {$ENDIF}
begin
  Combined := AnsiString(Trim(Key) + WS_MAGIC);

  {$IFDEF FPC}
  SHA1Init(SHA1Ctx);
  SHA1Update(SHA1Ctx, @Combined[1], Length(Combined));
  SHA1Final(SHA1Ctx, Digest);
  SetLength(DigestBytes, 20);
  for I := 0 to 19 do
    DigestBytes[I] := Digest[I];
  Result := EncodeStringBase64(string(AnsiString(PAnsiChar(@DigestBytes[0]))));
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
  {$ELSE}
  HashBytes := THashSHA1.GetHashBytes(string(Combined));
  Result := TNetEncoding.Base64.EncodeBytesToString(HashBytes);
  {$ENDIF}
end;

function StartsWithCI(const S, Prefix: string): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
            SameText(Copy(S, 1, Length(Prefix)), Prefix);
end;

function ExtractPath(const URL: string): string;
var
  QPos: Integer;
begin
  QPos := Pos('?', URL);
  if QPos > 0 then
    Result := Copy(URL, 1, QPos - 1)
  else
    Result := URL;
end;

function GetQueryParam(const URL, ParamName: string): string;
var
  QPos, Start, EqPos, AmpPos: Integer;
  QueryStr, Pair, Name: string;
begin
  Result := '';
  QPos := Pos('?', URL);
  if QPos = 0 then Exit;

  QueryStr := Copy(URL, QPos + 1, MaxInt);
  Start := 1;
  while Start <= Length(QueryStr) do
  begin
    AmpPos := PosEx('&', QueryStr, Start);
    if AmpPos = 0 then
      AmpPos := Length(QueryStr) + 1;
    Pair := Copy(QueryStr, Start, AmpPos - Start);
    EqPos := Pos('=', Pair);
    if EqPos > 0 then
    begin
      Name := Copy(Pair, 1, EqPos - 1);
      if SameText(Name, ParamName) then
      begin
        Result := Copy(Pair, EqPos + 1, MaxInt);
        Exit;
      end;
    end;
    Start := AmpPos + 1;
  end;
end;

function GetTickCount64MS: Int64;
begin
  Result := {$IFDEF FPC}GetTickCount64{$ELSE}Windows.GetTickCount64{$ENDIF};
end;

end.