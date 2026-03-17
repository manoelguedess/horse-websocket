object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Horse websocket'
  ClientHeight = 155
  ClientWidth = 813
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
    Left = 8
    Top = 8
    Width = 121
    Height = 21
    TabOrder = 0
    Text = 'edtPort'
  end
  object btnStart: TBitBtn
    Left = 8
    Top = 35
    Width = 121
    Height = 50
    Caption = 'Start'
    TabOrder = 1
    OnClick = btnStartClick
  end
  object btnStop: TBitBtn
    Left = 8
    Top = 91
    Width = 121
    Height = 50
    Caption = 'Stop'
    TabOrder = 2
    OnClick = btnStopClick
  end
  object MemoLog: TMemo
    Left = 135
    Top = 8
    Width = 666
    Height = 133
    Lines.Strings = (
      'MemoLog')
    ScrollBars = ssVertical
    TabOrder = 3
  end
end
