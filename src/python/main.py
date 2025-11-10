# To make the interaction between Zig and Python more straight forward, the Python part is written like a state machine.
# Which means that every operation modifies the current state and will effect the functioning of later operations.

from marker.model import Marker

marker = None

# Initialize a marker model.
def init_marker(device: str, width: int, height: int, depth: int):
    global marker

    marker = Marker(device, width, height, depth)

# Load a marker model.
def load_marker(device: str, path: str):
    global marker

    marker = Marker.load(device, path)

# Save the marker model
def save_marker(path: str):
    global marker

    if marker == None:
        raise Exception("No marker model loaded.")

    marker.save(path)
