/*******************************************************************************
* Copyright 2019-2025 Intel Corporation
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*******************************************************************************/

#include <sstream>

#include "dnnl_common.hpp"
#include "dnnl_debug.hpp"

#include "eltwise/eltwise.hpp"

namespace eltwise {

std::string prb_t::set_repro_line() {
    dnnl::impl::stringstream_t s;
    dump_global_params(s);
    settings_t def;

    if (canonical || dir != def.dir[0]) s << "--dir=" << dir << " ";
    if (canonical || dt != def.dt[0]) s << "--dt=" << dt << " ";
    if (canonical || tag != def.tag[0]) s << "--tag=" << tag << " ";
    s << "--alg=" << alg << " ";
    s << "--alpha=" << alpha << " ";
    s << "--beta=" << beta << " ";
    if (canonical || inplace != def.inplace[0])
        s << "--inplace=" << bool2str(inplace) << " ";

    s << attr;
    if (canonical || ctx_init != def.ctx_init[0])
        s << "--ctx-init=" << ctx_init << " ";
    if (canonical || ctx_exe != def.ctx_exe[0])
        s << "--ctx-exe=" << ctx_exe << " ";
    if (canonical || !impl_filter.is_def() || !global_impl_filter.is_def())
        s << impl_filter;

    s << static_cast<prb_dims_t>(*this);

    return s.str();
}

} // namespace eltwise
