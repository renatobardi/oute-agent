import tempfile, time, statistics
from agent_studio.app import create_app
from agent_studio.config import load
from studio_db import StudioDB
from studio_asgi import TOKEN, get
cfg=load()
rows=[]
for run in range(5):
    with tempfile.TemporaryDirectory() as d:
        db=StudioDB(d, 'measure')
        now=time.time_ns()
        for i in range(700):
            db.span(now-(i+1)*840*10**9, 2, model='model-test', conv=f'conv-{i}', task=f'task-{i%20}', input=1000, output=100)
        app=create_app(db.flush(),TOKEN,config=cfg)
        start=time.perf_counter(); status,html=get(app,'/','hours=168'); elapsed=time.perf_counter()-start
        assert status==200
        rows.append(elapsed*1000)
print('700 spans / 700 conversas, 7 dias, 5 bancos novos, ASGI local: ms',rows,'mediana',statistics.median(rows))
