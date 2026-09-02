"""ComfyUI custom nodes for MiniMax-H3 video generation on merak.

`merak_api` talks to the service; `merak_nodes` is the ComfyUI side.
"""

from .merak_nodes import NODE_CLASS_MAPPINGS, NODE_DISPLAY_NAME_MAPPINGS

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
