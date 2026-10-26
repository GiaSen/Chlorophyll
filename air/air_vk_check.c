/*
 * SPDX-License-Identifier: MIT
 *
 * Host check of the AIR -> NIR -> Vulkan-binding path (air_to_nir + air_nir_vk.c), no GPU needed: every function of the
 * given .metallib files is translated, bridged, validated (a debug build validates NIR) and serialized, as Turnip does
 * when it hashes a pipeline stage.
 *   air_vk_check [-v] LIB.metallib...
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nir.h"
#include "nir_air.h"
#include "air_nir_vk.h"
#include "nir_serialize.h"
#include "compiler/glsl_types.h"
#include "ir3/ir3_compiler.h"
#include "common/freedreno_dev_info.h"
#include "util/blob.h"
#include "util/ralloc.h"

int
main(int argc, char **argv)
{
   bool verbose = argc > 1 && !strcmp(argv[1], "-v");
   glsl_type_singleton_init_or_ref();
   struct fd_dev_id id = { .gpu_id = 630, .chip_id = 0x06030001 };
   struct ir3_compiler_options opts = { 0 };
   struct ir3_compiler *ir3 = ir3_compiler_create(NULL, &id, fd_dev_info_raw(&id), &opts);
   const nir_shader_compiler_options *nopts = ir3_get_compiler_options(ir3);
   unsigned ok = 0, refused = 0, bridge_fail = 0;
   for (int a = verbose ? 2 : 1; a < argc; a++) {
      FILE *f = fopen(argv[a], "rb");
      if (!f) { perror(argv[a]); return 2; }
      fseek(f, 0, SEEK_END);
      size_t n = ftell(f);
      fseek(f, 0, SEEK_SET);
      void *data = malloc(n);
      if (fread(data, 1, n, f) != n) return 2;
      fclose(f);
      void *mem = ralloc_context(NULL);
      struct air_metallib lib;
      const char *err = NULL;
      if (!air_metallib_parse(mem, data, n, &lib, &err)) { printf("%s: %s\n", argv[a], err); continue; }
      for (unsigned i = 0; i < lib.num_functions; i++) {
         const struct air_metallib_function *fn = &lib.functions[i];
         struct air_constant_value *constants;
         unsigned nc = air_module_function_constants(mem, fn->bitcode, fn->bitcode_size, &constants);
         struct air_to_nir_options o = { .constants = constants, .num_constants = nc };
         struct air_shader_info info;
         nir_shader *nir = air_to_nir(mem, fn->bitcode, fn->bitcode_size, fn->name, &o, nopts, &info, &err);
         if (!nir) {
            refused++;
            if (verbose) printf("  %-40s refused: %s\n", fn->name, err);
            continue;
         }
         struct air_vk_layout layout = { 0 };
         char why[256] = "";
         unsigned stage = info.stage == MESA_SHADER_FRAGMENT ? 1 : 0;
         if (!air_nir_to_vulkan(nir, &info, stage, &layout, why, sizeof(why))) {
            bridge_fail++;
            printf("  %-40s bridge: %s\n", fn->name, why);
            continue;
         }
         nir_validate_shader(nir, "after air_nir_to_vulkan");
         struct blob b;
         blob_init(&b);
         nir_serialize(&b, nir, false);
         if (verbose) {
            printf("  %-40s ok, %zu bytes serialized, push %u, bindings:", fn->name, b.size, layout.push_bytes);
            for (unsigned k = 0; k < AIR_VK_MAX_BINDINGS; k++)
               if (layout.type[k]) printf(" %u:%d", k, layout.type[k] - 1);
            printf("\n");
            if (getenv("AIR_VK_PRINT")) nir_print_shader(nir, stdout);
         }
         blob_finish(&b);
         ok++;
      }
      ralloc_free(mem);
      free(data);
   }
   printf("== %u bridged and serialized, %u refused by the frontend, %u refused by the bridge\n", ok, refused, bridge_fail);
   return bridge_fail ? 1 : 0;
}
