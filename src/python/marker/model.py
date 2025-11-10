from time import time
import torch

from utilities import fit_tensor
from marker.unet import UNet

# A model which marks the input image and output a mask
class Marker:

    # Load a marker model from a file.
    @staticmethod
    def load(device: str, path: str):
        data = torch.load(path, device)
        marker = Marker(device, data["width"], data["height"], data["depth"])

        marker.model.load_state_dict(data["model_state"])
        marker.optimizer.load_state_dict(data["optimizer_state"])

        marker.loss = data["loss"]
        marker.iterations = data["iterations"]

        return marker

    # Initialize a marker model.
    def __init__(self, device: str, width: int, height: int, depth: int):
        self.device = torch.device(device)
        self.model = UNet(3, 1, depth).to(self.device)

        self.width = width
        self.height = height
        self.depth = depth

        self.loss = 1.0
        self.iterations = 0

        self.criterion = torch.nn.BCEWithLogitsLoss()
        self.optimizer = torch.optim.Adam(self.model.parameters(), lr = 1e-4)

    # Mark an image.
    def mark(self, image: torch.Tensor):
        self.model.eval()

        with torch.no_grad():
            resized_tensor, transform = fit_tensor(image, self.width, self.height)

            output = self.model(resized_tensor.to(self.device))
            output = output[:, :, transform[1]:transform[1] + transform[3], transform[0]:transform[0] + transform[2]]
            output = torch.nn.functional.interpolate(output, size=(image.shape[2], image.shape[3]))

            return torch.sigmoid(output)

    # Train the marker model.
    def train(self, loader: torch.utils.data.DataLoader):
        start = time()
        average = []

        self.model.train()

        for images, masks in loader:
            self.optimizer.zero_grad()

            images = images.to(self.device, non_blocking=True)
            masks = masks.to(self.device, non_blocking=True)
            
            predictions = self.model(images)
            loss = self.criterion(predictions, masks)

            self.optimizer.zero_grad()
            loss.backward()
            self.optimizer.step()

            average.append(loss.item())

        self.loss = sum(average) / len(average)
        self.iterations += 1

        return {
            "loss": self.loss,
            "iterations": self.iterations,
            "duration": round(time() - start)
        }

    # Save the marker model.
    def save(self, path: str):
        torch.save({
            "width": self.width,
            "height": self.height,
            "depth": self.depth,

            "loss": self.loss,
            "iterations": self.iterations,

            "model_state": self.model.state_dict(),
            "optimizer_state": self.optimizer.state_dict()
        }, path)
