#!/usr/bin/env bash
#
# Script informed by the collectd monitoring script for smartmontools (using smartctl)
# by Samuel B. <samuel_._behan_(at)_dob_._sk> (c) 2012
# source at: http://devel.dob.sk/collectd-scripts/

# TODO: This probably needs to be a little more complex.  The raw numbers can have more
#       data in them than you'd think.
#       http://arstechnica.com/civis/viewtopic.php?p=22062211

# Formatting done via shfmt -i 2
# https://github.com/mvdan/sh

# Ensure predictable numeric / date formats, etc.
export LC_ALL=C

parse_smartctl_attributes_awk="$(
  cat <<'SMARTCTLAWK'
$1 ~ /^ *[0-9]+$/ && $2 ~ /^[a-zA-Z0-9_-]+$/ {
  gsub(/-/, "_");
  printf "%s_value{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $4
  printf "%s_worst{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $5
  printf "%s_threshold{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $6
  printf "%s_raw_value{%s,smart_id=\"%s\"} %e\n", $2, labels, $1, $10
}
SMARTCTLAWK
)"

smartmon_attrs="$(
  cat <<'SMARTMONATTRS'
airflow_temperature_cel
command_timeout
current_pending_sector
end_to_end_error
erase_fail_count
g_sense_error_rate
hardware_ecc_recovered
host_reads_32mib
host_reads_mib
host_writes_32mib
host_writes_mib
load_cycle_count
media_wearout_indicator
nand_writes_1gib
offline_uncorrectable
power_cycle_count
power_on_hours
program_fail_cnt_total
program_fail_count
raw_read_error_rate
reallocated_event_count
reallocated_sector_ct
reported_uncorrect
runtime_bad_block
sata_downshift_count
seek_error_rate
spin_retry_count
spin_up_time
start_stop_count
temperature_case
temperature_celsius
temperature_internal
total_lbas_read
total_lbas_written
udma_crc_error_count
unsafe_shutdown_count
unused_rsvd_blk_cnt_tot
wear_leveling_count
workld_host_reads_perc
workld_media_wear_indic
workload_minutes
SMARTMONATTRS
)"
smartmon_attrs="$(echo "${smartmon_attrs}" | xargs | tr ' ' '|')"

parse_smartctl_attributes() {
  local disk="$1"
  local disk_type="$2"
  local labels="disk=\"${disk}\",type=\"${disk_type}\""
  sed 's/^ \+//g' |
    awk -v labels="${labels}" "${parse_smartctl_attributes_awk}" 2>/dev/null |
    tr '[:upper:]' '[:lower:]' |
    grep -E "(${smartmon_attrs})"
}

parse_smartctl_scsi_attributes() {
  local disk="$1"
  local disk_type="$2"
  local labels="disk=\"${disk}\",type=\"${disk_type}\""
  while read -r line; do
    attr_type="$(echo "${line}" | tr '=' ':' | cut -f1 -d: | sed 's/^ \+//g' | tr ' ' '_')"
    attr_value="$(echo "${line}" | tr '=' ':' | cut -f2 -d: | sed 's/^ \+//g')"
    case "${attr_type}" in
    number_of_hours_powered_up_) power_on="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Current_Drive_Temperature) temp_cel="$(echo "${attr_value}" | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_sent_to_initiator_) lbas_read="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_received_from_initiator_) lbas_written="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Accumulated_start-stop_cycles) power_cycle="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Elements_in_grown_defect_list) grown_defects="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    esac
  done
  [ -n "$power_on" ] && echo "power_on_hours_raw_value{${labels},smart_id=\"9\"} ${power_on}"
  [ -n "$temp_cel" ] && echo "temperature_celsius_raw_value{${labels},smart_id=\"194\"} ${temp_cel}"
  [ -n "$lbas_read" ] && echo "total_lbas_read_raw_value{${labels},smart_id=\"242\"} ${lbas_read}"
  [ -n "$lbas_written" ] && echo "total_lbas_written_raw_value{${labels},smart_id=\"241\"} ${lbas_written}"
  [ -n "$power_cycle" ] && echo "power_cycle_count_raw_value{${labels},smart_id=\"12\"} ${power_cycle}"
  [ -n "$grown_defects" ] && echo "grown_defects_count_raw_value{${labels},smart_id=\"-1\"} ${grown_defects}"
}

parse_smartctl_nvme_attributes() {
  local disk="$1"
  local disk_type="$2"
  local labels="disk=\"${disk}\",type=\"${disk_type}\""
  local critical_warning="" temperature="" available_spare="" available_spare_threshold=""
  local percentage_used="" data_units_read="" data_units_written=""
  local host_read_commands="" host_write_commands="" controller_busy_time=""
  local power_cycles="" power_on_hours="" unsafe_shutdowns=""
  local media_errors="" error_log_entries=""
  local warning_temp_time="" critical_temp_time=""
  while read -r line; do
    local key val
    key="$(echo "${line}" | sed 's/^ *//;s/ *$//' | cut -f1 -d:)"
    val="$(echo "${line}" | cut -f2- -d: | sed 's/^ *//;s/,//g;s/%//g')"
    case "${key}" in
    "Critical Warning") critical_warning="$(echo "${val}" | awk '{ printf "%d\n", $1 + 0 }')" ;;
    "Temperature") temperature="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Available Spare") available_spare="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Available Spare Threshold") available_spare_threshold="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Percentage Used") percentage_used="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Data Units Read") data_units_read="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Data Units Written") data_units_written="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Host Read Commands") host_read_commands="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Host Write Commands") host_write_commands="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Controller Busy Time") controller_busy_time="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Power Cycles") power_cycles="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Power On Hours") power_on_hours="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Unsafe Shutdowns") unsafe_shutdowns="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Media and Data Integrity Errors") media_errors="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Error Information Log Entries") error_log_entries="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Warning  Comp. Temperature Time") warning_temp_time="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    "Critical Comp. Temperature Time") critical_temp_time="$(echo "${val}" | awk '{ printf "%e\n", $1 }')" ;;
    esac
  done
  [ -n "$critical_warning" ] && echo "nvme_critical_warning{${labels}} ${critical_warning}"
  [ -n "$temperature" ] && echo "temperature_celsius_raw_value{${labels},smart_id=\"194\"} ${temperature}"
  [ -n "$available_spare" ] && echo "nvme_available_spare_percent{${labels}} ${available_spare}"
  [ -n "$available_spare_threshold" ] && echo "nvme_available_spare_threshold_percent{${labels}} ${available_spare_threshold}"
  [ -n "$percentage_used" ] && echo "nvme_percentage_used{${labels}} ${percentage_used}"
  [ -n "$data_units_read" ] && echo "nvme_data_units_read{${labels}} ${data_units_read}"
  [ -n "$data_units_written" ] && echo "nvme_data_units_written{${labels}} ${data_units_written}"
  [ -n "$host_read_commands" ] && echo "nvme_host_read_commands{${labels}} ${host_read_commands}"
  [ -n "$host_write_commands" ] && echo "nvme_host_write_commands{${labels}} ${host_write_commands}"
  [ -n "$controller_busy_time" ] && echo "nvme_controller_busy_time{${labels}} ${controller_busy_time}"
  [ -n "$power_cycles" ] && echo "power_cycle_count_raw_value{${labels},smart_id=\"12\"} ${power_cycles}"
  [ -n "$power_on_hours" ] && echo "power_on_hours_raw_value{${labels},smart_id=\"9\"} ${power_on_hours}"
  [ -n "$unsafe_shutdowns" ] && echo "nvme_unsafe_shutdowns{${labels}} ${unsafe_shutdowns}"
  [ -n "$media_errors" ] && echo "nvme_media_errors{${labels}} ${media_errors}"
  [ -n "$error_log_entries" ] && echo "nvme_error_log_entries{${labels}} ${error_log_entries}"
  [ -n "$warning_temp_time" ] && echo "nvme_warning_temp_time{${labels}} ${warning_temp_time}"
  [ -n "$critical_temp_time" ] && echo "nvme_critical_temp_time{${labels}} ${critical_temp_time}"
}

parse_smartctl_info() {
  local -i smart_available=0 smart_enabled=0 smart_healthy=
  local disk="$1" disk_type="$2"
  local model_family='' device_model='' serial_number='' fw_version='' vendor='' product='' revision='' lun_id=''
  while read -r line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_')"
    info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"
    case "${info_type}" in
    Model_Family) model_family="${info_value}" ;;
    Device_Model) device_model="${info_value}" ;;
    Model_Number) device_model="${info_value}" ;;
    Serial_Number|Serial_number) serial_number="${info_value}" ;;
    Firmware_Version) fw_version="${info_value}" ;;
    Vendor) vendor="${info_value}" ;;
    Product) product="${info_value}" ;;
    Revision) revision="${info_value}" ;;
    Logical_Unit_id) lun_id="${info_value}" ;;
    esac
    if [[ "${info_type}" == 'SMART_support_is' ]]; then
      case "${info_value:0:7}" in
      Enabled) smart_available=1; smart_enabled=1 ;;
      Availab) smart_available=1; smart_enabled=0 ;;
      Unavail) smart_available=0; smart_enabled=0 ;;
      esac
    fi
    # NVMe devices report health directly without "SMART support is" lines
    if [[ "${info_type}" == 'SMART/Health_Information_(NVMe_Log_0x02)' ]]; then
      smart_available=1; smart_enabled=1
    fi
    if [[ "${info_type}" == 'SMART_overall-health_self-assessment_test_result' ]]; then
      case "${info_value:0:6}" in
      PASSED) smart_healthy=1; smart_available=1; smart_enabled=1 ;;
      *) smart_healthy=0 ;;
      esac
    elif [[ "${info_type}" == 'SMART_Health_Status' ]]; then
      case "${info_value:0:2}" in
      OK) smart_healthy=1 ;;
      *) smart_healthy=0 ;;
      esac
    fi
  done
  echo "device_info{disk=\"${disk}\",type=\"${disk_type}\",vendor=\"${vendor}\",product=\"${product}\",revision=\"${revision}\",lun_id=\"${lun_id}\",model_family=\"${model_family}\",device_model=\"${device_model}\",serial_number=\"${serial_number}\",firmware_version=\"${fw_version}\"} 1"
  echo "device_smart_available{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_available}"
  echo "device_smart_enabled{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_enabled}"
  [[ "${smart_healthy}" != "" ]] && echo "device_smart_healthy{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_healthy}"
}

output_format_awk="$(
  cat <<'OUTPUTAWK'
BEGIN { v = "" }
v != $1 {
  print "# HELP smartmon_" $1 " SMART metric " $1;
  print "# TYPE smartmon_" $1 " gauge";
  v = $1
}
{print "smartmon_" $0}
OUTPUTAWK
)"

format_output() {
  sort |
    awk -F'{' "${output_format_awk}"
}

smartctl_version="$(/usr/sbin/smartctl -V | head -n1 | awk '$1 == "smartctl" {print $2}')"

echo "smartctl_version{version=\"${smartctl_version}\"} 1" | format_output

if [[ "$(expr "${smartctl_version}" : '\([0-9]*\)\..*')" -lt 6 ]]; then
  exit
fi

device_list="$(/usr/sbin/smartctl --scan-open | awk '/^\/dev/{print $1 "|" $3}')"

for device in ${device_list}; do
  disk="$(echo "${device}" | cut -f1 -d'|')"
  type="$(echo "${device}" | cut -f2 -d'|')"

  if [ "${type}" = "sat" ]; then
    # Quick check: does it fail to identify as SAT but respond to JMicron?
    if ! /usr/sbin/smartctl -i -d sat "${disk}" > /dev/null 2>&1; then
       if /usr/sbin/smartctl -i -d sntjmicron "${disk}" > /dev/null 2>&1; then
          type="sntjmicron"
       fi
       if /usr/sbin/smartctl -i -d sntrealtek "$disk" > /dev/null 2>&1; then
         type="sntrealtek"
       fi
    fi
  fi


  active=1
  echo "smartctl_run{disk=\"${disk}\",type=\"${type}\"}" "$(TZ=UTC date '+%s')"
  # Check if the device is in a low-power mode
  /usr/sbin/smartctl -n standby -d "${type}" "${disk}" > /dev/null || active=0
  echo "device_active{disk=\"${disk}\",type=\"${type}\"}" "${active}"
  # Skip further metrics to prevent the disk from spinning up
  test ${active} -eq 0 && continue
  # Get the SMART information and health
  /usr/sbin/smartctl -i -H -d "${type}" "${disk}" | parse_smartctl_info "${disk}" "${type}"
  # Get the SMART attributes
  case ${type} in
  sat) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk}" "${type}" ;;
  sat+megaraid*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk}" "${type}" ;;
  scsi) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk}" "${type}" ;;
  megaraid*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk}" "${type}" ;;
  nvme*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_nvme_attributes "${disk}" "${type}" ;;
  usbprolific) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk}" "${type}" ;;
  sntjmicron) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_nvme_attributes "${disk}" "${type}" ;;
  sntrealtek) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_nvme_attributes "${disk}" "${type}" ;;
  *)
      (>&2 echo "disk type is not sat, scsi, nvme or megaraid but ${type}")
    exit
    ;;
  esac
done | format_output
