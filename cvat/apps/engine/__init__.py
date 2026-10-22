# Copyright (C) 2018-2022 Intel Corporation
# Copyright (C) CVAT.ai Corporation
#
# SPDX-License-Identifier: MIT

# schema is imported from EngineConfig.ready(). Importing it here pulls
# rest_framework while Django settings are still loading, and APIView then
# freezes the stock auth, permission, and schema classes.
