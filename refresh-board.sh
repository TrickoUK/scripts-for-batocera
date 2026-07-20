#!/bin/bash

# After changing some config in the arcade board variant, rebuild everything needed for the build to pick it up.
make x86_64-arcade-defconfig
make x86_64-arcade-config BATCH_MODE=1
make x86_64-arcade-build CMD="batocera-es-system-dirclean batocera-es-system" BATCH_MODE=1


