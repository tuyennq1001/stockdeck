import {spawn} from 'node:child_process';
import path from 'node:path';
import {nativeBundle} from './runtime-config.mjs';

// Only a POC process watchdog. Does not claim OS sandboxing or a hard memory ceiling.
export function runNative(jobPath, timeoutMs = 5000, bundleOverride = nativeBundle) {
  return new Promise(resolve => {
    const start=performance.now();
    const child=spawn('/usr/bin/time',['-l',path.resolve('local/jsc-runner'),
      path.resolve(bundleOverride),path.resolve(jobPath),
      path.resolve('jsc-job.js')],{detached:true,stdio:['ignore','pipe','pipe']});
    let stdout='',stderr='',timedOut=false,oversize=false,spawnError;
    const kill=()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}};
    const timer=setTimeout(()=>{timedOut=true;kill();},timeoutMs);
    child.stdout.on('data',data=>{stdout+=data;if(stdout.length>8*1024*1024){oversize=true;kill();}});
    child.stderr.on('data',data=>{stderr+=data;});
    child.on('error',error=>{spawnError=String(error);});
    child.on('close',(code,signal)=>{
      clearTimeout(timer);
      let output;
      try {output=JSON.parse(stdout);}catch{}
      const timing=stderr.match(/([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys/);
      const rss=stderr.match(/(\d+)\s+maximum resident set size/);
      resolve({code,signal,timedOut,oversize,spawnError,wallMs:performance.now()-start,
        cpuMs:timing?(Number(timing[2])+Number(timing[3]))*1000:null,
        peakRSSBytes:rss?Number(rss[1]):null,output,
        error:output?undefined:stderr.slice(0,1000)});
    });
  });
}
