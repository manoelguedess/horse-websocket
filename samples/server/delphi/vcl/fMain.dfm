object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Horse websocket'
  ClientHeight = 260
  ClientWidth = 601
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  Position = poScreenCenter
  OnClose = FormClose
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 13
  object edtPort: TEdit
    Left = 345
    Top = 175
    Width = 248
    Height = 21
    TabOrder = 1
    Text = 'edtPort'
  end
  object btnStart: TBitBtn
    Left = 345
    Top = 202
    Width = 121
    Height = 50
    Caption = 'Start'
    TabOrder = 2
    OnClick = btnStartClick
  end
  object btnStop: TBitBtn
    Left = 472
    Top = 202
    Width = 121
    Height = 50
    Caption = 'Stop'
    TabOrder = 3
    OnClick = btnStopClick
  end
  object MemoLog: TMemo
    Left = 8
    Top = 8
    Width = 585
    Height = 145
    Lines.Strings = (
      'MemoLog')
    ScrollBars = ssVertical
    TabOrder = 0
  end
end
