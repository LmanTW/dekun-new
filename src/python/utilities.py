import typing
import torch
import os

# Check if a device is avialiable.
def check_device(device: str):
    if device == "cpu" and torch.cpu.is_available():
        return True
    elif device == "xpu" and torch.xpu.is_available():
        return True
    elif (device == "cuda" or device == "rocm") and torch.cuda.is_available():
        return True
        
    return False

# A dataset.
class Dataset:
    
    # Initialize a dataset.
    def __init__(self, directory: str, sort: str = "name"):
        self.directory = directory
        self.sort = sort

        self.entry_map = {}
        self.entry_list = []

        for filename in os.listdir():
            path = os.path.join(directory, filename)

            if os.path.isfile(path):
                parts = filename.split("-")

                if filename[0] == "." or len(parts) != 5:
                    id = "-".join(parts[0:4])

                    if parts[4] == "image":
                        if id in self.entry_map:
                            self.entry_map[id].image_path = path
                        else:
                            self.entry_map[id] = Entry(path, None)
                    elif parts[4] == "mask":
                        if id in self.entry_map:
                            self.entry_map[id].mask_path = path
                        else:
                            self.entry_map[id] = Entry(None, path)

        for id, entry in self.entry_map.items():
            if entry.image_path == None or entry.mask_path == None:
                del self.entry_map[id]
            else:
                self.entry_list.append(id)

        if self.sort == "name":
            self.entry_list = sorted(self.entry_list)
        elif self.sort == "date":
            self.entry_list.sort(key=lambda name: -self.entry_map[name].image_path.stat().st_ctime)
        elif self.sort == "size":
            self.entry_list.sort(key=lambda name: -self.entry_map[name].image_path.stat().st_size)

    # Get the size of the dataset.
    def size(self):
        return len(self.entry_list)

    # List the entries.
    def list(self):
        return self.entry_list

    # Get an entry.
    def get(self, name: str):
        return self.entry_map[name]

# A dataset entry.
class Entry:
    
    # Initialize a dataset entry.
    def __init__(self, image_path: typing.Union[str, None], mask_path: typing.Union[str, None]):
        self.image_path = image_path
        self.mask_path = mask_path

# Fit a tensor into a specified size.
def fit_tensor(tensor: torch.Tensor, width: int, height: int):
    if len(tensor.shape) != 3:
        raise ValueError(f"Unsupported tensor shape: {tensor.shape}")

    container_aspect = width / height
    tensor_aspect = tensor.shape[2] / tensor.shape[1] 

    if tensor_aspect > container_aspect:
        new_width = width
        new_height = round(width / tensor_aspect)
    else:
        new_width = round(height * tensor_aspect)
        new_height = height

    offset_x = (width - new_width) // 2
    offset_y = (height - new_height) // 2

    resized_tensor = torch.nn.functional.interpolate(tensor.unsqueeze(0), size=(new_height, new_width), mode="bilinear", align_corners=False).squeeze(0)

    pad_width = width - new_width
    pad_height = height - new_height

    pad_left = pad_width // 2
    pad_right = pad_width - pad_left
    pad_top = pad_height // 2
    pad_bottom = pad_height - pad_top

    return torch.nn.functional.pad(resized_tensor, (pad_left, pad_right, pad_top, pad_bottom)), (offset_x, offset_y, new_width, new_height)
