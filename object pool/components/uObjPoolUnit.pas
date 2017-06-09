unit uObjPoolUnit;

interface

{
  ͨ�õĶ����
  create by rocklee, 9/Jun/2017
  QQ:1927368378
  Ӧ�����ӣ�
  FPool := TObjPool.Create(10);  //����һ������������10������Ļ�������
  FPool.OnNewObjectEvent := onNewObject; //�����½�������¼�
  FPool.setUIThreadID(tthread.CurrentThread.ThreadID); //�������̵߳�ThreadID
  FPool.WaitQueueSize := 100; //�Ŷӵȴ����������
  FPool.OnStatusEvent:=onStatus; //status���
  ...
  var lvObj:Tobject;
  lvObj := FPool.getObject(); //�ӳ��л�ö���
  ...
  FPool.returnObject(lvObj); //�黹����

}
uses
  classes, System.Contnrs, forms, sysutils,SyncObjs;

type
  TOnNewObjectEvent = function(): Tobject of object;
  TOnStatusEvent = procedure(const pvStatus: String) of object;

  TObjPool = class(TQueue)
  private
    /// <summary>
    /// ����ش�С
    /// </summary>
    fCapacity: Cardinal;
    fSize: Cardinal;
    fUIThreadID: THandle;
    fOnNewObjectEvent: TOnNewObjectEvent;
    fWaitCounter: integer;
    fWaitQueueSize: integer;
    fOnStatusEvent: TOnStatusEvent;
    fLockObj: integer;
    fLock:TCriticalSection;
    function innerPopItem(): Tobject;
    procedure doStatus(const pvStatus: STring);
  public
    procedure Lock;
    procedure UnLock;
    /// <summary>
    /// ���ؿ�ʱ�ȴ��Ķ�����������������ȴ������ʱ��ֱ�ӷ���ʧ��
    /// </summary>
    property WaitQueueSize: integer read fWaitQueueSize write fWaitQueueSize;
    /// <summary>
    /// �Ӷ�����л�ö��������Ϊ��ʱ�������OnNewObjectEvent�½�����
    ///
    /// </summary>
    function getObject(pvCurThreadID: THandle = 0): Tobject; virtual;
    /// <summary>
    /// �黹����
    /// </summary>
    procedure returnObject(pvObject: Tobject); virtual;
    /// <summary>
    /// ��ǰ���������Ķ����ܹ�����
    /// </summary>
    property MntSize: Cardinal read fSize;
    /// <summary>
    /// ��ǰ�ȴ�����������
    /// </summary>
    property CurWaitCounter: integer read fWaitCounter;
    /// <summary>
    /// ��õ�ǰ����������
    /// </summary>
    function getPoolSize: integer;
    property OnStatusEvent: TOnStatusEvent read fOnStatusEvent write fOnStatusEvent;
    procedure Clear;
    procedure setUIThreadID(pvThreadID: THandle);
    constructor Create(pvCapacity: Cardinal);
    destructor destroy; override;
    property OnNewObjectEvent: TOnNewObjectEvent read fOnNewObjectEvent
      write fOnNewObjectEvent;

  end;

implementation

procedure SpinLock(var Target: integer);
begin
  while AtomicCmpExchange(Target, 1, 0) <> 0 do
  begin
{$IFDEF SPINLOCK_SLEEP}
    Sleep(1); // 1 �Ա�0 (�߳�Խ�࣬�ٶ�Խƽ��)
{$ENDIF}
  end;
end;

procedure SpinUnLock(var Target: integer);
begin
  if AtomicCmpExchange(Target, 0, 1) <> 1 then
  begin
    Assert(False, 'SpinUnLock::AtomicCmpExchange(Target, 0, 1) <> 1');
  end;
end;

{ TObjPool }

procedure TObjPool.Clear;
var
  lvObj: Pointer;
  lvCC:integer;
begin
  // �����ȥ���Ƿ�ȫ���黹
  doStatus(Format('���������:%d,���ж�����%d',[self.MntSize,count]));
  Assert(self.Count = fSize, format('����%d����������û�黹', [MntSize - self.Count]));
  lvCC:=0;
  repeat
    lvObj := innerPopItem();
    if lvObj<>nil then begin
        TObject(lvObj).Destroy;
        INC(lvCC);
    end;
  until lvObj=nil;
  fSize:=0;
  doStatus(format('����%d����',[lvCC]));
  inherited;
end;

constructor TObjPool.Create(pvCapacity: Cardinal);
begin
  inherited Create;
  fLock:=TCriticalSection.Create;
  fSize := 0;
  fWaitCounter := 0;
  fCapacity := pvCapacity;
  fUIThreadID := 0;
  fLockObj := 0;
  fOnNewObjectEvent := nil;
  fOnStatusEvent := nil;
end;

destructor TObjPool.destroy;
begin
  Clear;
  fLock.Destroy;
  inherited;
end;

procedure TObjPool.doStatus(const pvStatus: STring);
begin
  if (@fOnStatusEvent = nil) then
    exit;
  fOnStatusEvent(pvStatus);
end;

function TObjPool.getObject(pvCurThreadID: THandle = 0): Tobject;
var
  lvCurTheadID: THandle;
begin
  Assert(@fOnNewObjectEvent <> nil, 'OnNewObectEvent is not assigned!');
  result := innerPopItem();
  if result <> nil then
  begin
    exit;
  end;
  if fWaitCounter > fWaitQueueSize then
  begin // ǰ���Ŷ���������ָ���������˳�
    doStatus('ǰ���Ŷ���������ָ�����ޣ��˳�...');
    exit;
  end;

  if fSize = fCapacity then
  begin // �Ѿ��ﵽ���ޣ��ȴ�
    // sfLogger.logMessage('�ŶӵȺ�...');
    doStatus('�ŶӵȺ�...');
    // InterlockedIncrement(fWaitCounter);
    AtomicIncrement(fWaitCounter);
    if pvCurThreadID <> 0 then
      lvCurTheadID := pvCurThreadID
    else
      lvCurTheadID := TThread.CurrentThread.ThreadID;
    while (result = nil) do
    begin
      if (lvCurTheadID = fUIThreadID) then
      begin
        Application.ProcessMessages;
      end;
      Sleep(1);
      result := innerPopItem();
    end;
    AtomicDecrement(fWaitCounter);
    exit;
  end;
  Lock;
  try
    result := fOnNewObjectEvent();
  finally
    UnLock;
  end;
  AtomicIncrement(fSize);
end;

function TObjPool.getPoolSize: integer;
begin
  result := Count;
end;

function TObjPool.innerPopItem: Tobject;
begin
  Lock;
  try
    if Count=0 then begin
       result:=nil;
       exit;
    end;
    result := Tobject(self.PopItem());
  finally
    UnLock;
  end;
end;

procedure TObjPool.Lock;
begin
  SpinLock(fLockObj);
  //fLock.Enter;
end;
procedure TObjPool.UnLock;
begin
  SpinUnLock(fLockObj);
  //fLock.Leave;
end;

procedure TObjPool.returnObject(pvObject: Tobject);
begin
  Lock;
  try
    self.PushItem(pvObject);
  finally
    UnLock;
  end;
end;

procedure TObjPool.setUIThreadID(pvThreadID: THandle);
begin
  fUIThreadID := pvThreadID;
end;


end.
