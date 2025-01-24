// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Device table API auto-generated by `dtgen`
<%
from topgen.lib import Name, is_top_reggen, is_ipgen

module_types = {m["type"] for m in top["module"]}
module_types = sorted(module_types)

def snake_to_constant_name(s):
    return Name.from_snake_case(s).as_camel_case()

include_guard = "OPENTITAN_TOP_{}_DEVICETABLES_H_".format(top["name"].upper())
%>\

#ifndef ${include_guard}
#define ${include_guard}

#include "dt/dt_api.h" // Generated.

% for header in sorted(dt_headers):
#include "${header}" // Generated.
% endfor

// Number of instances of each module.
enum {
% for module_name in module_types:
<%
    modules = [m for m in top["module"] if m["type"] == module_name]
%>\
  kDt${snake_to_constant_name(module_name)}Count = ${len(modules)},
% endfor
};

% for module_name in module_types:
<%
    modules = [m for m in top["module"] if m["type"] == module_name]
%>\
// Instance names for ${module_name}
enum {
  % for m in modules:
  kDtIndex${snake_to_constant_name(m["name"])},
  % endfor
};

% endfor

% for module_name in module_types:
// Device tables for ${module_name}
extern const dt_${module_name}_t kDt${snake_to_constant_name(module_name)}[kDt${snake_to_constant_name(module_name)}Count];
% endfor

#endif  // ${include_guard}
