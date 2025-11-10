import torch.nn as nn
import torch

# A double convolutional block.
class DoubleConvolutionalBlock(nn.Module):

    # Initialize a double convolutional block.
    def __init__(self, in_channels: int, out_channels: int):
        super(DoubleConvolutionalBlock, self).__init__()

        self.block = nn.Sequential(
            nn.Conv2d(in_channels, out_channels, kernel_size=3, padding=1),
            nn.BatchNorm2d(out_channels),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_channels, out_channels, kernel_size=3, padding=1),
            nn.BatchNorm2d(out_channels),
            nn.ReLU(inplace=True)
        )
    
    # Forward the convolutional block.
    def forward(self, input: torch.Tensor):
        return self.block(input)

# A standard U-Net.
class UNet(nn.Module):

    # Initialize a U-Net.
    def __init__(self, in_channels: int, out_channels: int, depth: int = 5):
        super(UNet, self).__init__()

        self.downs = nn.ModuleList()
        self.ups = nn.ModuleList()
        self.pool = nn.MaxPool2d(kernel_size=2, stride=2)

        features = []

        for _ in range(depth):
            features.append(64 if len(features) == 0 else features[-1] * 2)

        for feature in features:
            self.downs.append(DoubleConvolutionalBlock(in_channels, feature))
            in_channels = feature

        self.bottleneck = DoubleConvolutionalBlock(features[-1], features[-1] * 2)

        for feature in reversed(features):
            self.ups.append(nn.ConvTranspose2d(feature * 2, feature, kernel_size=2, stride=2))
            self.ups.append(DoubleConvolutionalBlock(feature * 2, feature))

        self.final_convolution = nn.Conv2d(features[0], out_channels, kernel_size=1)

    # Forward the U-Net. 
    def forward(self, input: torch.Tensor):
        factor = 2 ** len(self.downs)

        if (input.shape[3] % factor != 0) or (input.shape[2] % factor != 0):
            raise ValueError(f"Invalid input size: {input.shape[3]} x {input.shape[2]} (not divisible by {factor})")

        skip_connections = []

        for down in self.downs:
            input = down(input)
            skip_connections.append(input)
            input = self.pool(input)

        input = self.bottleneck(input)
        skip_connections = skip_connections[::-1]

        for index in range(0, len(self.ups), 2):
            input = self.ups[index](input)
            skip_connection = skip_connections[index // 2]

            concat_skip = torch.cat((skip_connection, input), dim=1)
            input = self.ups[index + 1](concat_skip)

        return self.final_convolution(input)
