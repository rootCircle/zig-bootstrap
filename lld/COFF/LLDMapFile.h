//===- LLDMapFile.h ---------------------------------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLD_COFF_LLDMAPFILE_H
#define LLD_COFF_LLDMAPFILE_H

namespace lld::coff {
class COFFLinkerContext;
void writeLLDMapFile(const COFFLinkerContext &ctx);
}

#endif
