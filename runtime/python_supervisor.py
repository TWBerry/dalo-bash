#!/usr/bin/env python3
import argparse, contextlib, ctypes, io, os, secrets, signal, threading, traceback, time, select
import multiprocessing as mp
ABI='DALO-PY'; VERSION='1'; REQUEST_VERSION='1.1'; MAX_HEADER=4096; MAX_PAYLOAD=16*1024*1024

def read_exact(f,n):
 b=bytearray()
 while len(b)<n:
  x=f.read(n-len(b))
  if not x: raise EOFError
  b+=x
 return bytes(b)
class RequestReader:
 def __init__(self,f): self.f=f; self.buf=bytearray()
 def _readline(self):
  while True:
   i=self.buf.find(b'\n')
   if i>=0:
    out=bytes(self.buf[:i+1]); del self.buf[:i+1]; return out
   if len(self.buf)>MAX_HEADER: raise ValueError('header_too_long')
   x=self.f.read(65536)
   if not x: raise EOFError
   self.buf+=x
 def read_frame(self):
  h=self._readline()
  if len(h)>MAX_HEADER or not h.endswith(b'\n'): raise ValueError('header_too_long')
  p=h[:-1].decode('ascii').split('|')
  if len(p)!=5 or p[:3]!=[ABI,REQUEST_VERSION,'REQ']: raise ValueError('bad_frame')
  rid=int(p[3]); delim=p[4]
  if not delim or len(delim)>256 or not delim.isascii(): raise ValueError('bad_delimiter')
  marker=b'\n'+delim.encode('ascii')+b'\n'
  while True:
   i=self.buf.find(marker)
   if i>=0:
    if i>MAX_PAYLOAD: raise ValueError('bad_length')
    payload=bytes(self.buf[:i]); del self.buf[:i+len(marker)]
    return rid,payload
   if len(self.buf)>MAX_PAYLOAD+len(marker): raise ValueError('bad_length')
   x=self.f.read(65536)
   if not x: raise EOFError
   self.buf+=x
def write_frame(f,rid,p):
 f.write(f'{ABI}|{VERSION}|RESP|{rid}|{len(p)}\n'.encode()+p); f.flush()

def worker(c):
 """Execute worker requests; c is the duplex supervisor control pipe.

 On Linux/Android, PR_SET_PDEATHSIG prevents workers from surviving a
 SIGKILL of their supervisor. The parent-PID recheck closes the race where
 the supervisor exits between process creation and prctl registration.
 """
 if os.name == 'posix' and hasattr(signal, 'SIGKILL'):
  parent_pid = os.getppid()
  try:
   libc = ctypes.CDLL(None, use_errno=True)
   if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), 'PR_SET_PDEATHSIG')
   if os.getppid() != parent_pid:
    os.kill(os.getpid(), signal.SIGKILL)
  except (AttributeError, OSError):
   # Other POSIX systems may lack Linux prctl; recovery tests expose this.
   pass
 ns={'__name__':'__dalo_worker__'}
 while True:
  try:m=c.recv()
  except EOFError:return
  if m[0]=='QUIT':return
  req,mode,code=m; o,e=io.StringIO(),io.StringIO()
  try:
   with contextlib.redirect_stdout(o),contextlib.redirect_stderr(e):
    if mode=='EVAL': r=repr(eval(compile(code,'<dalo>','eval'),ns,ns))
    else: exec(compile(code,'<dalo>','exec'),ns,ns); r=''
   c.send((req,'OK',r,o.getvalue(),e.getvalue()))
  except BaseException:
   c.send((req,'FAILED','',o.getvalue(),e.getvalue()+traceback.format_exc()))
# Spawn starts a fresh interpreter instead of forking the multithreaded supervisor.
# A module-level context keeps Pipe and Process on the same multiprocessing backend.
WORKER_CONTEXT = mp.get_context("spawn")


def spawn():
 """Start one isolated worker using the spawn multiprocessing context.

 Parameters: none. Returns the child Process and parent control Connection.
 The child endpoint is always closed in the parent, including start failures.
 """
 parent, child = WORKER_CONTEXT.Pipe()
 try:
  process = WORKER_CONTEXT.Process(target=worker, args=(child,), daemon=True)
  process.start()
 except BaseException:
  parent.close()
  raise
 finally:
  child.close()
 return process, parent

class Slot:
 def __init__(self,i):
  self.i=i; self.g=1; self.lease=None; self.owner=None; self.state='FREE'; self.running=None
  self.lock=threading.RLock(); self.p,self.c=spawn()
 def _replace_worker(self):
  if self.p.is_alive(): self.p.terminate(); self.p.join(.20)
  if self.p.is_alive(): self.p.kill(); self.p.join()
  try:self.c.close()
  except Exception:pass
  self.g+=1; self.p,self.c=spawn()
 def invalidate_crash(self):
  self.lease=None; self.owner=None; self.running=None; self.state='RESPAWNING'; self._replace_worker(); self.state='FREE'
 def controlled_reset(self,keep_lease):
  old=self.lease; self.state='STOPPING'; self.running=None; self._replace_worker()
  self.lease=old if keep_lease else None; self.owner=self.owner if keep_lease else None; self.state='RESERVED' if keep_lease else 'FREE'

class Sup:
 def __init__(self,n):
  self.instance=secrets.token_hex(16); self.slots=[Slot(i) for i in range(n)]; self.lock=threading.RLock(); self.jobs={}; self.sessions={}; self.recovery_tokens={}; self.recovering=set(); self.had_session=False; self.shutting_down=threading.Event()
 def shutdown(self):
  with self.lock:
   if self.shutting_down.is_set(): return
   self.shutting_down.set()
   for j in self.jobs.values():
    if j['state'] in ('QUEUED','RUNNING'):
     j['state']='CANCELLED'; j['result']=b'FAILED|CANCELLED|SHUTDOWN\n'; j['updated']=time.time()
  for s in self.slots:
   with s.lock:
    s.state='STOPPING'; s.running=None; s.lease=None; s.owner=None
    try:
     if s.p.is_alive(): s.p.terminate(); s.p.join(.20)
     if s.p.is_alive(): s.p.kill(); s.p.join()
    finally:
     try:s.c.close()
     except Exception:pass
    s.state='FREE'
 def accepting(self): return not self.shutting_down.is_set()
 def register(self, identity, pid):
  """Register a client. identity is a unique session token; pid is its OS process ID. Return whether registration succeeded."""
  with self.lock:
   if not self.accepting(): return False
   self.sessions[identity]=pid; self.recovery_tokens[identity]=secrets.token_hex(32); self.had_session=True
   return True
 def detach(self, identity):
  """Detach identity, invalidate its worker leases and cancel its jobs. Return True only when it was the last client."""
  with self.lock:
   if identity not in self.sessions: return False
   del self.sessions[identity]
   self.recovery_tokens.pop(identity,None)
   self.recovering.discard(identity)
   last=self.had_session and not self.sessions
  for slot in self.slots:
   with slot.lock:
    if slot.owner != identity: continue
    running=slot.running
    slot.controlled_reset(keep_lease=False)
   if running:
    with self.lock:
     job=self.jobs.get(running)
     if job:
      job['state']='CANCELLED'; job['result']=b'FAILED|CANCELLED|CLIENT_DISCONNECTED\n'; job['updated']=time.time()
  if last:
   with self.lock:
    if not self.sessions: self.shutting_down.set()
  return last

 def lookup(self,a,identity):
  if len(a)<5 or a[1]!=self.instance:return None,'STALE_INSTANCE'
  try:s=self.slots[int(a[2])]; g=int(a[3])
  except Exception:return None,'BAD_SLOT'
  if g!=s.g or a[4]!=s.lease or s.lease is None:return None,'STALE_HANDLE'
  if s.owner!=identity:return None,'NOT_OWNER'
  return s,None
 def reserve(self,identity):
  """Reserve one free worker without waiting behind unrelated running slots.

  Parameters:
      identity: Supervisor session identity that will own the new lease.

  RUNNING workers are monitored while holding their per-slot lock during short
  control-pipe polls.  A blocking scan from slot zero can therefore starve
  allocation of later FREE slots.  Read the state as a cheap candidate filter,
  then lock and revalidate only slots which currently look FREE.
  """
  with self.lock:
   if identity not in self.sessions or identity in self.recovering:return b'FAILED|SESSION_DETACHED\n'
   for s in self.slots:
    if s.state!='FREE' or s.lease is not None:
     continue
    with s.lock:
     if s.state=='FREE' and s.lease is None:
      s.lease=secrets.token_hex(24); s.owner=identity; s.state='RESERVED'
      return f'OK|{self.instance}|{s.i}|{s.g}|{s.lease}\n'.encode()
  return b'DENIED|NO_FREE_SLOT\n'
 def execute_sync(self,s,op,code,jobid,identity):
  """Execute a synchronous job only while its lease is still owned.

  Parameters: s is the slot; op is EVAL/EXEC; code is Python source;
  jobid identifies the request; identity is the original session owner.
  """
  with s.lock:
   if s.owner!=identity:return b'FAILED|STALE_HANDLE\n'
   if s.state!='RESERVED': return b'DENIED|SLOT_BUSY\n'
   if not s.p.is_alive(): s.invalidate_crash(); return b'FAILED|WORKER_DIED|HANDLE_INVALID\n'
   s.state='RUNNING'; s.running=jobid; conn=s.c; proc=s.p; gen=s.g
   try:conn.send((jobid,op,code))
   except Exception:
    s.invalidate_crash(); return b'FAILED|WORKER_DIED|HANDLE_INVALID\n'
  while True:
   with s.lock:
    if s.g!=gen or s.running!=jobid:
     return b'FAILED|CANCELLED|HANDLE_UPDATED\n'
    if conn.poll(.03):
     try:req,st,r,o,e=conn.recv()
     except (EOFError,OSError): req=None
     if req==jobid:
      s.running=None; s.state='RESERVED'; break
    if not proc.is_alive():
     s.invalidate_crash(); return b'FAILED|WORKER_DIED|HANDLE_INVALID\n'
  eb=[x.encode() for x in (r,o,e)]
  return f'DONE|{st}|{len(eb[0])}|{len(eb[1])}|{len(eb[2])}\n'.encode()+b''.join(eb)
 def async_monitor(self,s,jobid,gen,conn,proc):
  result=None
  while True:
   with s.lock:
    if s.g!=gen or s.running!=jobid:
     result=b'FAILED|CANCELLED|HANDLE_UPDATED\n'; break
    if conn.poll(.03):
     try:req,st,r,o,e=conn.recv()
     except (EOFError,OSError):req=None
     if req==jobid:
      s.running=None; s.state='RESERVED'
      eb=[x.encode() for x in (r,o,e)]
      result=f'DONE|{st}|{len(eb[0])}|{len(eb[1])}|{len(eb[2])}\n'.encode()+b''.join(eb); break
    if not proc.is_alive():
     s.invalidate_crash(); result=b'FAILED|WORKER_DIED|HANDLE_INVALID\n'; break
  with self.lock:
   j=self.jobs.get(jobid)
   if not j or j['state'] in ('CANCELLED', 'DONE', 'FAILED'):return
   if result.startswith(b'DONE|OK|'):j['state']='DONE'
   elif result.startswith(b'DONE|'):j['state']='FAILED'
   elif b'CANCELLED' in result:j['state']='CANCELLED'
   else:j['state']='FAILED'
   j['result']=result;j['updated']=time.time()
 def start_async(self,s,op,code,jobid,identity):
  """Atomically authorize, dispatch and publish an asynchronous job.

  Parameters:
      s: Worker slot associated with the supplied lease.
      op: Worker operation (EVAL or EXEC).
      code: Python source sent to the worker.
      jobid: Unique identifier for the asynchronous request.
      identity: Session identity that must still own the slot.

  Always acquire the supervisor lock before the slot lock. Recovery claims
  acquire the supervisor lock to fence an old identity, so they cannot
  interleave between dispatch and job publication. The monitor starts only
  after both locks are released.
  """
  with self.lock:
   if identity not in self.sessions or identity in self.recovering:
    return b'FAILED|SESSION_DETACHED\n'
   if jobid in self.jobs:
    return b'FAILED|DUPLICATE_JOB\n'
   with s.lock:
    if s.owner!=identity:return b'FAILED|STALE_HANDLE\n'
    if s.state!='RESERVED':return b'DENIED|SLOT_BUSY\n'
    if not s.p.is_alive():s.invalidate_crash();return b'FAILED|WORKER_DIED|HANDLE_INVALID\n'
    gen=s.g;conn=s.c;proc=s.p;s.state='RUNNING';s.running=jobid
    try:conn.send((jobid,op,code))
    except Exception:s.invalidate_crash();return b'FAILED|WORKER_DIED|HANDLE_INVALID\n'
    self.jobs[jobid]={'state':'RUNNING','result':b'','updated':time.time(),'slot':s.i,'generation':gen,'owner':identity}
  threading.Thread(target=self.async_monitor,args=(s,jobid,gen,conn,proc),daemon=True).start()
  return f'ACCEPTED|{jobid}|{self.instance}|{s.i}|{gen}\n'.encode()
 def handle(self,p,rid,identity):
  line,_,data=p.partition(b'\n'); a=line.decode().split('|'); op=a[0]
  if op=='SHUTDOWN':
   if len(a)!=2 or a[1]!=self.instance:return b'FAILED|STALE_INSTANCE\n'
   with self.lock:
    if identity not in self.sessions or identity in self.recovering:return b'FAILED|SESSION_DETACHED\n'
   last=self.detach(identity); return f'OK|SHUTDOWN|{self.instance}|{"LAST" if last else "DETACHED"}\n'.encode()
  if not self.accepting():return b'DENIED|SHUTTING_DOWN\n'
  with self.lock:
   if identity not in self.sessions or identity in self.recovering:return b'FAILED|SESSION_DETACHED\n'
  if op=='PING':
   with self.lock:
    token=self.recovery_tokens.get(identity)
   if not token:return b'FAILED|SESSION_DETACHED\n'
   return f'OK|{self.instance}|{len(self.slots)}|{token}\n'.encode()
  if op=='RECOVER':
   # Parameters: instance ID and the previous session's private recovery token.
   # A successful response proves the old session was detached and its slots reset.
   if len(a)!=3 or a[1]!=self.instance:return b'FAILED|STALE_INSTANCE\n'
   # Claim the token and fence the old identity atomically. Never hold the
   # global lock while resetting workers: reset acquires per-slot locks.
   with self.lock:
    old=next((sid for sid,tok in self.recovery_tokens.items()
              if sid!=identity and secrets.compare_digest(tok,a[2])),None)
    if old is None or old in self.recovering:
     return b'FAILED|UNKNOWN_SESSION\n'
    self.recovering.add(old)
    self.recovery_tokens.pop(old,None)
   # Detach synchronously; success is sent only after all owned slots reset.
   self.detach(old)
   return f'OK|RECOVER|{self.instance}|DETACHED\n'.encode()
  if op=='RESERVE':return self.reserve(identity)
  if op=='STATUS':
   if len(a)!=2:return b'FAILED|BAD_REQUEST\n'
   with self.lock:j=self.jobs.get(a[1])
   if not j or j.get('owner')!=identity:return b'FAILED|UNKNOWN_JOB\n'
   if j['state'] in ('DONE','FAILED','CANCELLED'):
    return b'JOB|'+j['state'].encode()+b'|'+a[1].encode()+b'\n'+j['result']
   return f"JOB|{j['state']}|{a[1]}\n".encode()
  if op=='AFFINITY':
   # Set CPU affinity only for the process owned by this exact worker lease.
   # Parameters: a carries instance, slot, generation, lease and CPU; identity is the caller session.
   if len(a)!=6:return b'FAILED|BAD_REQUEST\n'
   try:
    cpu=int(a[5])
    if cpu<0 or str(cpu)!=a[5]:raise ValueError
   except ValueError:return b'FAILED|BAD_CPU\n'
   s,e=self.lookup(a,identity)
   if e:return f'FAILED|{e}\n'.encode()
   with s.lock:
    s2,e=self.lookup(a,identity)
    if e or s2 is not s:return f'FAILED|{e or "STALE_HANDLE"}\n'.encode()
    if not s.p.is_alive():s.invalidate_crash();return b'FAILED|WORKER_DIED|HANDLE_INVALID\n'
    try:
     os.sched_setaffinity(s.p.pid,{cpu})
     actual=os.sched_getaffinity(s.p.pid)
    except (AttributeError,OSError,ValueError) as exc:
     return f'FAILED|AFFINITY_UNAVAILABLE|{type(exc).__name__}\n'.encode()
    if actual!={cpu}:return b'FAILED|AFFINITY_MISMATCH\n'
    return f'OK|AFFINITY|{s.i}|{s.g}|{cpu}|{s.p.pid}\n'.encode()
  if op in ('STOP','RELEASE'):
   s,e=self.lookup(a,identity)
   if e:return f'FAILED|{e}\n'.encode()
   with s.lock:
    # Revalidate the lease while holding the slot lock. Never acquire the
    # supervisor lock here: RESERVE acquires supervisor -> slot.
    s2,e=self.lookup(a,identity)
    if e or s2 is not s:return f'FAILED|{e or "STALE_HANDLE"}\n'.encode()
    running=s.running
    s.controlled_reset(keep_lease=(op=='STOP'))
    # Capture the response while the slot generation is still protected.
    if op=='STOP':reply=f'OK|{self.instance}|{s.i}|{s.g}|{s.lease}\n'.encode()
    else:reply=f'OK|RELEASE|{s.i}|{s.g}\n'.encode()
   # A concurrent monitor may publish before this section. Its terminal-state
   # guard prevents it from overwriting cancellation once recorded.
   if running:
    with self.lock:
     job=self.jobs.get(running)
     if job and job['state'] in ('QUEUED','RUNNING'):
      job['state']='CANCELLED'; job['result']=b'FAILED|CANCELLED|STOPPED\n'; job['updated']=time.time()
   return reply
  if op not in ('EVAL','EXEC'):return b'FAILED|UNKNOWN_OPCODE\n'
  s,e=self.lookup(a,identity)
  if e:return f'FAILED|{e}\n'.encode()
  try:
   n=None if a[5]=='-' else int(a[5]); flags=int(a[6]) if len(a)>6 else 0
  except Exception:return b'FAILED|BAD_REQUEST\n'
  if n is not None and n!=len(data):return b'FAILED|BAD_CODE_LENGTH\n'
  try:code=data.decode('utf-8')
  except UnicodeDecodeError:return b'FAILED|CODE_NOT_UTF8\n'
  jobid=str(rid)
  if flags & 1:
   with self.lock:
    if jobid in self.jobs:return b'FAILED|DUPLICATE_JOB\n'
   return self.start_async(s,op,code,jobid,identity)
  return self.execute_sync(s,op,code,jobid,identity)

def session(sup, identity, pid, inf, outf, req):
 """Serve identity for client pid using inf/outf FIFOs; notify req on final teardown. sup owns the shared slots."""
 try:
  fdin=os.open(inf,os.O_RDWR); fdout=os.open(outf,os.O_RDWR)
  with os.fdopen(fdin,'rb',0) as fi,os.fdopen(fdout,'wb',0) as fo:
   reader=RequestReader(fi)
   while identity in sup.sessions and not sup.shutting_down.is_set():
    try:
     rid,p=reader.read_frame()
     response=sup.handle(p,rid,identity)
     write_frame(fo,rid,response)
     if p.startswith(b'SHUTDOWN|'):break
    except EOFError:break
    except Exception as e:
     try:write_frame(fo,0,('FAILED|TRANSPORT|'+str(e)+'\n').encode())
     except Exception:break
 finally:
  last=sup.detach(identity)
  if last or sup.shutting_down.is_set():
   try:
    with open(req,'w') as wake:wake.write('__SHUTDOWN__\n')
   except OSError:pass

def watch_clients(sup,req):
 """Poll registered client PIDs in sup and notify req when an orphaned final session is removed."""
 while not sup.shutting_down.wait(.25):
  with sup.lock: clients=list(sup.sessions.items())
  for identity,pid in clients:
   try:os.kill(pid,0)
   except ProcessLookupError:
    if sup.detach(identity):
     try:
      with open(req,'w') as wake:wake.write('__SHUTDOWN__\n')
     except OSError:pass
   except PermissionError:pass

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--root',required=True);ap.add_argument('--workers',type=int,required=True);z=ap.parse_args()
 os.makedirs(z.root,mode=0o700,exist_ok=True); req=z.root+'/request.fifo'
 try:os.mkfifo(req,0o600)
 except FileExistsError:pass
 sup=Sup(z.workers)
 threading.Thread(target=watch_clients,args=(sup,req),daemon=True).start()
 with open(z.root+'/ready','w') as f:f.write(sup.instance+'\n')
 with open(z.root+'/supervisor.pid','w') as f:f.write(str(os.getpid())+'\n')
 fd=os.open(req,os.O_RDWR)
 with os.fdopen(fd,'r') as f:
  for line in f:
   q=line.rstrip('\n').split('|')
   if line.rstrip('\n')=='__SHUTDOWN__':break
   if len(q)==4 and q[0]=='REGISTER' and sup.accepting():
    try: pid=int(q[1]); identity=secrets.token_hex(16)
    except ValueError: continue
    if sup.register(identity,pid):
     threading.Thread(target=session,args=(sup,identity,pid,q[2],q[3],req),daemon=True).start()
 sup.shutdown()
 for name in os.listdir(z.root):
  path=os.path.join(z.root,name)
  try:
   if os.path.isdir(path):
    for child in os.listdir(path):
     try:os.unlink(os.path.join(path,child))
     except OSError:pass
    os.rmdir(path)
   else:os.unlink(path)
  except OSError:pass
if __name__=='__main__':main()
