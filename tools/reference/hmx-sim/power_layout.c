/* Prints the HAP_power_request_t layout and enum values the emitted HMX runtime needs,
 * computed by the SDK compiler from the SDK 6.4.0.2 headers. Test tool only. */
#include <stdio.h>
#include <stddef.h>
#include "HAP_power.h"
#include "HAP_compute_res.h"
int main(void) {
  printf("sizeof(HAP_power_request_t)=%u\n", (unsigned)sizeof(HAP_power_request_t));
  printf("offset type=%u hvx.power_up=%u hmx.power_up=%u\n", (unsigned)offsetof(HAP_power_request_t, type),
         (unsigned)offsetof(HAP_power_request_t, hvx.power_up), (unsigned)offsetof(HAP_power_request_t, hmx.power_up));
  printf("offset dcvs_v2.dcvs_enable=%u dcvs_option=%u set_dcvs_params=%u target_corner=%u min_corner=%u max_corner=%u\n",
         (unsigned)offsetof(HAP_power_request_t, dcvs_v2.dcvs_enable), (unsigned)offsetof(HAP_power_request_t, dcvs_v2.dcvs_option),
         (unsigned)offsetof(HAP_power_request_t, dcvs_v2.set_dcvs_params),
         (unsigned)offsetof(HAP_power_request_t, dcvs_v2.dcvs_params.target_corner),
         (unsigned)offsetof(HAP_power_request_t, dcvs_v2.dcvs_params.min_corner),
         (unsigned)offsetof(HAP_power_request_t, dcvs_v2.dcvs_params.max_corner));
  printf("sizeof field: hvx.power_up=%u hmx.power_up=%u dcvs_enable=%u dcvs_option=%u set_dcvs_params=%u corner=%u\n",
         (unsigned)sizeof(((HAP_power_request_t*)0)->hvx.power_up), (unsigned)sizeof(((HAP_power_request_t*)0)->hmx.power_up),
         (unsigned)sizeof(((HAP_power_request_t*)0)->dcvs_v2.dcvs_enable), (unsigned)sizeof(((HAP_power_request_t*)0)->dcvs_v2.dcvs_option),
         (unsigned)sizeof(((HAP_power_request_t*)0)->dcvs_v2.set_dcvs_params),
         (unsigned)sizeof(((HAP_power_request_t*)0)->dcvs_v2.dcvs_params.target_corner));
  printf("enum HAP_power_set_HVX=%d HAP_power_set_HMX=%d HAP_power_set_DCVS_v2=%d PERFORMANCE_MODE=%d VCORNER_TURBO=%d\n",
         (int)HAP_power_set_HVX, (int)HAP_power_set_HMX, (int)HAP_power_set_DCVS_v2, (int)HAP_DCVS_V2_PERFORMANCE_MODE, (int)HAP_DCVS_VCORNER_TURBO);
  printf("sizeof(compute_res_attr_t)=%u\n", (unsigned)sizeof(compute_res_attr_t));
  return 0;
}
