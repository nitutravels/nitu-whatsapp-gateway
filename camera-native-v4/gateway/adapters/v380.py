from __future__ import annotations
import asyncio, os
from .base import BaseAdapter
from gateway.media.sink import AnnexBHLSSink
from gateway.plugins.base import PluginContext
from gateway.plugins.loader import load_plugin, PluginLoadError

class V380Adapter(BaseAdapter):
    vendor='v380'
    async def run(self):
        spec=self.camera.get('native_plugin') or os.getenv('V380_NATIVE_PLUGIN','').strip() or 'gateway.plugins.v380_native:V380NativePlugin'
        try:
            plugin=load_plugin(spec)
            sink=AnnexBHLSSink(self.camera['id'],self.hls_root,getattr(plugin,'codec','h264'))
            self.status.decoder_ready=True
            self.status.set('connecting',f'native plugin loaded: {spec}')
            try:
                await plugin.run(PluginContext(self.camera,self.secrets,sink,self.status,self.stop_event))
            finally:
                await sink.stop()
        except (PluginLoadError, Exception) as exc:
            self.status.decoder_ready=False
            self.status.set('plugin_error',str(exc))
            while not self.stop_event.is_set():
                await asyncio.sleep(2)
