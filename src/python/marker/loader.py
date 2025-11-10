import torchvision
import torch

from utilities import Dataset, fit_tensor

# A marker dataset loader.
class MarkerLoader(torch.utils.data.Dataset):

    # Initialize a marker dataset loader.
    def __init__(self, dataset: Dataset, width: int, height: int):
        self.entries = []
        self.width = width
        self.height = height

        for name in dataset.list():
            entry = dataset.get(name)

            if entry.exists():
                self.entries.append(entry)

    # Get the size of the dataset.
    def __len__(self):
        return len(self.entries)

    # Get an entry.
    def __getitem__(self, index: int):
        entry = self.entries[index]

        image_tensor = fit_tensor(torchvision.io.decode_image(str(entry.image_path), torchvision.io.ImageReadMode.RGB), self.width, self.height)[0].float() / 255
        mask_tensor = fit_tensor(torchvision.io.decode_image(str(entry.mask_path), torchvision.io.ImageReadMode.GRAY), self.width, self.height)[0].float() / 255

        return image_tensor, mask_tensor
