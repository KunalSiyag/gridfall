import re,glob,os,sys
D=os.getcwd(); A='/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/4eb46f6b-fccd-4256-83c9-4c39144a74d2/scratchpad/artifact-files/96d9413f-7fc3-4f19-992b-0e4cd4e434cf'
local={'7a2f4de7c66a0c670d6c0c325dd33772':D+'/robot.jpg','e8ae7b52749c953a0ae7fb33c857417c':D+'/hero_crop.jpg',
 'eb01cddc82bde0d8947db8f5179c783b':D+'/portraits/argon.jpg','6c425b3cecc46e6f42daac0bf5d85c22':D+'/portraits/deepseek.jpg',
 '74446904b223e46cd662ed62e46a0d50':D+'/portraits/kimi.jpg','0746f1fce6353f0410b043f2e96ccf46':D+'/portraits/qwen.jpg','a3eb22804d151415300c2a3ddfc8aa5a':D+'/portraits/grok.jpg'}
for f in glob.glob('project/slides/*.html'):
    t=open(f).read(); sid=os.path.basename(f)[:-5]
    t=re.sub(r'/_blob/([0-9a-f]{32})',lambda m:'file://'+local.get(m.group(1),f'{A}/{m.group(1)}.jpg'),t)
    t=re.sub(r'<aside>[\s\S]*?</aside>','',t)
    t=t.replace('style="background','style="width:1920px;height:1080px;box-sizing:border-box;position:relative;overflow:hidden;background',1)
    open(f'prev/{sid}.html','w').write('<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&family=IBM+Plex+Sans:wght@400;600&family=JetBrains+Mono:wght@500&display=swap"><style>html,body{margin:0;padding:0;background:#000}p,h1,h2,h3{margin:0}ul{margin:0;padding:0}</style></head><body>'+t+'</body></html>')
