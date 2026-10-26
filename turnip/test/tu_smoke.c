// SPDX-License-Identifier: MIT
// Turnip (Mesa's Vulkan driver for Adreno) on the A630 under Bergamota, with no Vulkan loader: the ICD is linked directly and
// every entry point comes from vk_icdGetInstanceProcAddr. Step 1 is the smoke test (instance, device, a cleared image with one
// triangle drawn into it, read back and checked); step 2 times frames of N draws with the state changes a CoreAnimation frame
// makes per draw (pipeline switch, per-draw vertex bytes and constants at dynamic offsets, a texture), for comparison with
// test/bgair_drawbench.c on Gallium.
//   tu_smoke [draws=200] [frames=60]
// Built by turnip/build-test.sh; the ICD and the libdrm stand-in sit next to it (@executable_path).
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include "tri_vert.h"
#include "color_frag.h"
#include "tex_frag.h"

extern PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *name);
extern VkResult vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *version);

#define W 256
#define H 256
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("FAIL %s:%d %s -> %d\n", __FILE__, __LINE__, #x, r_); exit(1); } } while (0)

static double now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }

/* entry points */
#define IFN(n) static PFN_##n n;
#define DFN(n) static PFN_##n n;
IFN(vkCreateInstance) IFN(vkEnumeratePhysicalDevices) IFN(vkGetPhysicalDeviceProperties) IFN(vkGetPhysicalDeviceQueueFamilyProperties)
IFN(vkGetPhysicalDeviceMemoryProperties) IFN(vkCreateDevice) IFN(vkGetDeviceProcAddr) IFN(vkGetPhysicalDeviceProperties2)
DFN(vkGetDeviceQueue) DFN(vkCreateImage) DFN(vkGetImageMemoryRequirements) DFN(vkAllocateMemory) DFN(vkBindImageMemory)
DFN(vkCreateImageView) DFN(vkCreateBuffer) DFN(vkGetBufferMemoryRequirements) DFN(vkBindBufferMemory) DFN(vkMapMemory)
DFN(vkCreateRenderPass) DFN(vkCreateFramebuffer) DFN(vkCreateShaderModule) DFN(vkCreateDescriptorSetLayout) DFN(vkCreatePipelineLayout)
DFN(vkCreateGraphicsPipelines) DFN(vkCreateCommandPool) DFN(vkAllocateCommandBuffers) DFN(vkBeginCommandBuffer) DFN(vkEndCommandBuffer)
DFN(vkCmdBeginRenderPass) DFN(vkCmdEndRenderPass) DFN(vkCmdBindPipeline) DFN(vkCmdBindDescriptorSets) DFN(vkCmdDraw)
DFN(vkCmdCopyImageToBuffer) DFN(vkCmdPipelineBarrier) DFN(vkCmdCopyBufferToImage) DFN(vkQueueSubmit) DFN(vkCreateFence) DFN(vkWaitForFences)
DFN(vkResetFences) DFN(vkResetCommandBuffer) DFN(vkCreateDescriptorPool) DFN(vkAllocateDescriptorSets) DFN(vkUpdateDescriptorSets)
DFN(vkCreateSampler) DFN(vkCmdSetViewport) DFN(vkCmdSetScissor) DFN(vkDeviceWaitIdle) DFN(vkInvalidateMappedMemoryRanges)

static VkPhysicalDeviceMemoryProperties memprops;

static uint32_t
mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
   for (uint32_t i = 0; i < memprops.memoryTypeCount; i++)
      if ((bits & (1u << i)) && (memprops.memoryTypes[i].propertyFlags & want) == want)
         return i;
   printf("FAIL no memory type for bits %#x flags %#x\n", bits, want);
   exit(1);
}

static VkDevice dev;

static VkBuffer
make_buffer(VkDeviceSize size, VkBufferUsageFlags usage, VkDeviceMemory *mem, void **map)
{
   VkBuffer b;
   CHECK(vkCreateBuffer(dev, &(VkBufferCreateInfo){ .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage }, NULL, &b));
   VkMemoryRequirements req;
   vkGetBufferMemoryRequirements(dev, b, &req);
   CHECK(vkAllocateMemory(dev, &(VkMemoryAllocateInfo){ .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
      .memoryTypeIndex = mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) }, NULL, mem));
   CHECK(vkBindBufferMemory(dev, b, *mem, 0));
   CHECK(vkMapMemory(dev, *mem, 0, VK_WHOLE_SIZE, 0, map));
   return b;
}

static VkImage
make_image(VkFormat fmt, uint32_t w, uint32_t h, VkImageUsageFlags usage, VkImageView *view)
{
   VkImage img;
   CHECK(vkCreateImage(dev, &(VkImageCreateInfo){ .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = fmt,
      .extent = { w, h, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = usage, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED }, NULL, &img));
   VkMemoryRequirements req;
   vkGetImageMemoryRequirements(dev, img, &req);
   VkDeviceMemory mem;
   CHECK(vkAllocateMemory(dev, &(VkMemoryAllocateInfo){ .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
      .memoryTypeIndex = mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) }, NULL, &mem));
   CHECK(vkBindImageMemory(dev, img, mem, 0));
   CHECK(vkCreateImageView(dev, &(VkImageViewCreateInfo){ .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fmt, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } }, NULL, view));
   return img;
}

static VkShaderModule
shader(const uint32_t *code, size_t size)
{
   VkShaderModule m;
   CHECK(vkCreateShaderModule(dev, &(VkShaderModuleCreateInfo){ .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = size, .pCode = code }, NULL, &m));
   return m;
}

static void
barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to, VkAccessFlags sa, VkAccessFlags da,
        VkPipelineStageFlags ss, VkPipelineStageFlags ds)
{
   vkCmdPipelineBarrier(cb, ss, ds, 0, 0, NULL, 0, NULL, 1, &(VkImageMemoryBarrier){ .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = sa, .dstAccessMask = da, .oldLayout = from, .newLayout = to, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } });
}

int
main(int argc, char **argv)
{
   int draws = argc > 1 ? atoi(argv[1]) : 200, frames = argc > 2 ? atoi(argv[2]) : 60;
   setvbuf(stdout, NULL, _IOLBF, 0);
   double t0 = now_us();
   uint32_t iv = 5;
   vk_icdNegotiateLoaderICDInterfaceVersion(&iv);
#define LI(n) n = (PFN_##n)vk_icdGetInstanceProcAddr(NULL, #n)
   LI(vkCreateInstance);
   VkInstance inst;
   CHECK(vkCreateInstance(&(VkInstanceCreateInfo){ .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &(VkApplicationInfo){ .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "tu_smoke",
         .apiVersion = VK_API_VERSION_1_1 } }, NULL, &inst));
#undef LI
#define LI(n) n = (PFN_##n)vk_icdGetInstanceProcAddr(inst, #n); if (!n) { printf("FAIL no %s\n", #n); return 1; }
   LI(vkEnumeratePhysicalDevices) LI(vkGetPhysicalDeviceProperties) LI(vkGetPhysicalDeviceQueueFamilyProperties)
   LI(vkGetPhysicalDeviceMemoryProperties) LI(vkCreateDevice) LI(vkGetDeviceProcAddr) LI(vkGetPhysicalDeviceProperties2)
   uint32_t n = 0;
   CHECK(vkEnumeratePhysicalDevices(inst, &n, NULL));
   if (n == 0) { printf("FAIL no physical device (TU_DEBUG=startup says why)\n"); return 1; }
   VkPhysicalDevice pd;
   n = 1;
   vkEnumeratePhysicalDevices(inst, &n, &pd);
   VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
   VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv };
   vkGetPhysicalDeviceProperties2(pd, &p2);
   printf("device: %s, Vulkan %u.%u.%u, driver %s %s (%.1f ms to here)\n", p2.properties.deviceName, VK_API_VERSION_MAJOR(p2.properties.apiVersion),
          VK_API_VERSION_MINOR(p2.properties.apiVersion), VK_API_VERSION_PATCH(p2.properties.apiVersion), drv.driverName, drv.driverInfo,
          (now_us() - t0) / 1e3);
   vkGetPhysicalDeviceMemoryProperties(pd, &memprops);
   for (uint32_t i = 0; i < memprops.memoryTypeCount; i++)
      printf("  memory type %u: flags %#x heap %u\n", i, memprops.memoryTypes[i].propertyFlags, memprops.memoryTypes[i].heapIndex);

   float prio = 1;
   CHECK(vkCreateDevice(pd, &(VkDeviceCreateInfo){ .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &(VkDeviceQueueCreateInfo){ .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0,
         .queueCount = 1, .pQueuePriorities = &prio } }, NULL, &dev));
#define LD(n) n = (PFN_##n)vkGetDeviceProcAddr(dev, #n); if (!n) { printf("FAIL no %s\n", #n); return 1; }
   LD(vkGetDeviceQueue) LD(vkCreateImage) LD(vkGetImageMemoryRequirements) LD(vkAllocateMemory) LD(vkBindImageMemory)
   LD(vkCreateImageView) LD(vkCreateBuffer) LD(vkGetBufferMemoryRequirements) LD(vkBindBufferMemory) LD(vkMapMemory)
   LD(vkCreateRenderPass) LD(vkCreateFramebuffer) LD(vkCreateShaderModule) LD(vkCreateDescriptorSetLayout) LD(vkCreatePipelineLayout)
   LD(vkCreateGraphicsPipelines) LD(vkCreateCommandPool) LD(vkAllocateCommandBuffers) LD(vkBeginCommandBuffer) LD(vkEndCommandBuffer)
   LD(vkCmdBeginRenderPass) LD(vkCmdEndRenderPass) LD(vkCmdBindPipeline) LD(vkCmdBindDescriptorSets) LD(vkCmdDraw)
   LD(vkCmdCopyImageToBuffer) LD(vkCmdPipelineBarrier) LD(vkCmdCopyBufferToImage) LD(vkQueueSubmit) LD(vkCreateFence) LD(vkWaitForFences)
   LD(vkResetFences) LD(vkResetCommandBuffer) LD(vkCreateDescriptorPool) LD(vkAllocateDescriptorSets) LD(vkUpdateDescriptorSets)
   LD(vkCreateSampler) LD(vkCmdSetViewport) LD(vkCmdSetScissor) LD(vkDeviceWaitIdle) LD(vkInvalidateMappedMemoryRanges)
   VkQueue q;
   vkGetDeviceQueue(dev, 0, 0, &q);
   printf("device created (%.1f ms)\n", (now_us() - t0) / 1e3);

   /* target, readback buffer, a 4x4 texture */
   VkImageView rtv, texv;
   VkImage rt = make_image(VK_FORMAT_R8G8B8A8_UNORM, W, H, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &rtv);
   VkImage tex = make_image(VK_FORMAT_R8G8B8A8_UNORM, 4, 4, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, &texv);
   VkDeviceMemory rbm, upm, vbm, cbm;
   void *rbmap, *upmap, *vbmap, *cbmap;
   VkBuffer rb = make_buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &rbm, &rbmap);
   VkBuffer up = make_buffer(4 * 4 * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &upm, &upmap);
   for (int i = 0; i < 16; i++) ((uint32_t *)upmap)[i] = 0xff00ff00u;   /* opaque green (RGBA8: R=0 G=255 B=0 A=255) */
   const VkDeviceSize vstride = 256;                                   /* minStorageBufferOffsetAlignment-safe */
   VkBuffer vb = make_buffer(vstride * (draws + 1), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, &vbm, &vbmap);
   VkBuffer cb_ = make_buffer(vstride * (draws + 1), VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, &cbm, &cbmap);

   VkRenderPass rp;
   CHECK(vkCreateRenderPass(dev, &(VkRenderPassCreateInfo){ .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1,
      .pAttachments = &(VkAttachmentDescription){ .format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
         .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
         .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
         .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL },
      .subpassCount = 1, .pSubpasses = &(VkSubpassDescription){ .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
         .pColorAttachments = &(VkAttachmentReference){ 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL } } }, NULL, &rp));
   VkFramebuffer fb;
   CHECK(vkCreateFramebuffer(dev, &(VkFramebufferCreateInfo){ .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
      .attachmentCount = 1, .pAttachments = &rtv, .width = W, .height = H, .layers = 1 }, NULL, &fb));

   VkDescriptorSetLayoutBinding binds[3] = {
      { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_VERTEX_BIT, NULL },
      { 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL },
      { 2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL },
   };
   VkDescriptorSetLayout dsl;
   CHECK(vkCreateDescriptorSetLayout(dev, &(VkDescriptorSetLayoutCreateInfo){ .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = 3, .pBindings = binds }, NULL, &dsl));
   VkPipelineLayout pl;
   CHECK(vkCreatePipelineLayout(dev, &(VkPipelineLayoutCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = 1, .pSetLayouts = &dsl }, NULL, &pl));
   VkDescriptorPool dp;
   VkDescriptorPoolSize ps[3] = { { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1 }, { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1 },
                                  { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1 } };
   CHECK(vkCreateDescriptorPool(dev, &(VkDescriptorPoolCreateInfo){ .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
      .poolSizeCount = 3, .pPoolSizes = ps }, NULL, &dp));
   VkDescriptorSet ds;
   CHECK(vkAllocateDescriptorSets(dev, &(VkDescriptorSetAllocateInfo){ .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &dsl }, &ds));
   VkSampler smp;
   CHECK(vkCreateSampler(dev, &(VkSamplerCreateInfo){ .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_LINEAR,
      .minFilter = VK_FILTER_LINEAR, .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
      .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .maxLod = 0 }, NULL, &smp));
   VkWriteDescriptorSet wr[3] = {
      { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 0, .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, .pBufferInfo = &(VkDescriptorBufferInfo){ vb, 0, 96 } },
      { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 1, .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &(VkDescriptorImageInfo){ smp, texv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL } },
      { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 2, .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .pBufferInfo = &(VkDescriptorBufferInfo){ cb_, 0, 16 } },
   };
   vkUpdateDescriptorSets(dev, 3, wr, 0, NULL);

   /* two pipelines: flat colour, and a texture tap blended over what is there (the two kinds of CoreAnimation layer) */
   VkShaderModule vs = shader(spv_tri_vert, sizeof(spv_tri_vert)), fs_c = shader(spv_color_frag, sizeof(spv_color_frag)),
                  fs_t = shader(spv_tex_frag, sizeof(spv_tex_frag));
   VkPipeline pipe[2];
   double tp = now_us();
   for (int i = 0; i < 2; i++) {
      VkPipelineShaderStageCreateInfo st[2] = {
         { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
         { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = i ? fs_t : fs_c, .pName = "main" },
      };
      VkPipelineColorBlendAttachmentState blend = { .blendEnable = i == 1, .srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
         .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .colorBlendOp = VK_BLEND_OP_ADD, .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
         .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .alphaBlendOp = VK_BLEND_OP_ADD, .colorWriteMask = 0xf };
      VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
      CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &(VkGraphicsPipelineCreateInfo){
         .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = st,
         .pVertexInputState = &(VkPipelineVertexInputStateCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO },
         .pInputAssemblyState = &(VkPipelineInputAssemblyStateCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST },
         .pViewportState = &(VkPipelineViewportStateCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1, .scissorCount = 1 },
         .pRasterizationState = &(VkPipelineRasterizationStateCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 },
         .pMultisampleState = &(VkPipelineMultisampleStateCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT },
         .pColorBlendState = &(VkPipelineColorBlendStateCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1, .pAttachments = &blend },
         .pDynamicState = &(VkPipelineDynamicStateCreateInfo){ .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = 2, .pDynamicStates = dyn },
         .layout = pl, .renderPass = rp, .subpass = 0 }, NULL, &pipe[i]));
   }
   printf("2 pipelines compiled in %.1f ms\n", (now_us() - tp) / 1e3);

   VkCommandPool pool;
   CHECK(vkCreateCommandPool(dev, &(VkCommandPoolCreateInfo){ .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 }, NULL, &pool));
   VkCommandBuffer cb;
   CHECK(vkAllocateCommandBuffers(dev, &(VkCommandBufferAllocateInfo){ .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 }, &cb));
   VkFence fence;
   CHECK(vkCreateFence(dev, &(VkFenceCreateInfo){ .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }, NULL, &fence));
   const VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
   const VkClearValue clear = { .color = { .float32 = { 0, 0, 1, 1 } } };   /* blue */
   const VkRenderPassBeginInfo rpb = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp, .framebuffer = fb,
      .renderArea = { { 0, 0 }, { W, H } }, .clearValueCount = 1, .pClearValues = &clear };
   const VkViewport vp = { 0, 0, W, H, 0, 1 };
   const VkRect2D sc = { { 0, 0 }, { W, H } };

   /* ---- 1. smoke: upload the texture; clear blue, one red triangle over the middle; read back ---- */
   float *v0 = vbmap;
   float tri[24] = { -0.5f, -0.5f, 0, 1,  1, 0, 0, 1,   0.5f, -0.5f, 0, 1,  1, 0, 0, 1,   0, 0.5f, 0, 1,  1, 0, 0, 1 };
   memcpy(v0, tri, sizeof(tri));
   CHECK(vkBeginCommandBuffer(cb, &begin));
   barrier(cb, tex, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
           VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
   vkCmdCopyBufferToImage(cb, up, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &(VkBufferImageCopy){ .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
      .imageExtent = { 4, 4, 1 } });
   barrier(cb, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT,
           VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
   vkCmdBeginRenderPass(cb, &rpb, VK_SUBPASS_CONTENTS_INLINE);
   vkCmdSetViewport(cb, 0, 1, &vp);
   vkCmdSetScissor(cb, 0, 1, &sc);
   vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe[0]);
   uint32_t offs[2] = { 0, 0 };
   vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pl, 0, 1, &ds, 2, offs);
   vkCmdDraw(cb, 3, 1, 0, 0);
   vkCmdEndRenderPass(cb);
   vkCmdCopyImageToBuffer(cb, rt, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb, 1, &(VkBufferImageCopy){ .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
      .imageExtent = { W, H, 1 } });
   vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &(VkMemoryBarrier){ .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT }, 0, NULL, 0, NULL);
   CHECK(vkEndCommandBuffer(cb));
   double ts = now_us();
   CHECK(vkQueueSubmit(q, 1, &(VkSubmitInfo){ .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb }, fence));
   VkResult wr_ = vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull);
   printf("smoke submit+wait: %s in %.2f ms\n", wr_ == VK_SUCCESS ? "done" : "FENCE NOT SIGNALED", (now_us() - ts) / 1e3);
   if (wr_ != VK_SUCCESS) return 1;
   const uint32_t *px = rbmap;
   uint32_t centre = px[(H / 2) * W + W / 2], corner = px[2 * W + 2];
   int ok = centre == 0xff0000ffu && corner == 0xffff0000u;   /* RGBA8 little-endian: red = 0xff0000ff, blue = 0xffff0000 */
   unsigned red = 0, blue = 0;
   for (int i = 0; i < W * H; i++) { red += px[i] == 0xff0000ffu; blue += px[i] == 0xffff0000u; }
   printf("smoke: centre %08x corner %08x, %u red + %u blue of %u pixels (triangle area %u expected) -> %s\n", centre, corner, red, blue,
          W * H, W * H / 8, ok && red + blue == W * H ? "PASS" : "FAIL");
   if (!ok) return 1;

   /* ---- 2. frames of `draws` draws, alternating the two pipelines, per-draw vertex bytes and constants ---- */
   for (int i = 0; i < draws; i++) {
      float *v = (float *)((char *)vbmap + vstride * i);
      float x = -1 + 2.0f * (i % 16) / 16, y = -1 + 2.0f * (i / 16 % 16) / 16;
      float t[24] = { x, y, 0, 1,  1, 1, 1, 0.5f,   x + 0.25f, y, 0, 1,  1, 1, 1, 0.5f,   x, y + 0.25f, 0, 1,  1, 1, 1, 0.5f };
      memcpy(v, t, sizeof(t));
      float *c = (float *)((char *)cbmap + vstride * i);
      c[0] = 0.01f * (i % 7); c[1] = 0; c[2] = c[3] = 0;
   }
   double enc = 0, sub = 0, wait = 0, encmin = 1e30;
   for (int f = 0; f < frames + 3; f++) {
      CHECK(vkResetFences(dev, 1, &fence));
      CHECK(vkResetCommandBuffer(cb, 0));
      double a = now_us();
      CHECK(vkBeginCommandBuffer(cb, &begin));
      vkCmdBeginRenderPass(cb, &rpb, VK_SUBPASS_CONTENTS_INLINE);
      vkCmdSetViewport(cb, 0, 1, &vp);
      vkCmdSetScissor(cb, 0, 1, &sc);
      for (int i = 0; i < draws; i++) {
         vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe[i & 1]);
         uint32_t o[2] = { (uint32_t)(vstride * i), (uint32_t)(vstride * i) };
         vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pl, 0, 1, &ds, 2, o);
         vkCmdDraw(cb, 3, 1, 0, 0);
      }
      vkCmdEndRenderPass(cb);
      CHECK(vkEndCommandBuffer(cb));
      double b = now_us();
      CHECK(vkQueueSubmit(q, 1, &(VkSubmitInfo){ .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb }, fence));
      double c = now_us();
      CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull));
      double d = now_us();
      if (f >= 3) {   /* the first frames warm up (command stream pools, variant compiles) */
         enc += b - a; sub += c - b; wait += d - c;
         if (b - a < encmin) encmin = b - a;
      }
   }
   printf("bench: %d frames x %d draws: encode %.3f ms/frame (min %.3f) = %.2f us/draw, submit %.3f ms, GPU wait %.3f ms\n", frames, draws,
          enc / frames / 1e3, encmin / 1e3, enc / frames / draws, sub / frames / 1e3, wait / frames / 1e3);
   vkDeviceWaitIdle(dev);
   printf("total %.1f ms\n", (now_us() - t0) / 1e3);
   return 0;
}
