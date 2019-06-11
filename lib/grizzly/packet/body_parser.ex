defmodule Grizzly.Packet.BodyParser do
  @moduledoc """
  A special parser for parsing the Z/IP packet body

  Documents to understand the binary structure of the Z/IP packets are:

  - [Z-Wave Command Class XML file](https://github.com/Z-WavePublic/libzwaveip/tree/master/config)
  - SDS10242 Z-Wave Device Class Specifiction.pdf
  - SDS11846 Z-Wave Plus Role Type Specification.pdf
  - SDS11847 Z-Wave Plus Device Type Specificiation.pdf
  - SDS13781 Z-Wave Application Command Class Specificiation.pdf
  - SDS13782 Z-Wave Management Command Class Specificiation.pdf
  - SDS13783 Z-Wave Transport-Encapsulation Command Class Specification.pdf
  - SDS13784 Z-Wave Network-Protocol Command Class Specification.pdf
  - SDS14223 Z-Wave Command Class Control Specification.pdf
  - SDS14224 Z-Wave Plus v2 Device Type Specification.pdf

  All the above PDFs can be downloaded [here](https://www.silabs.com/products/wireless/mesh-networking/z-wave/specification)

  A useful list of all the command classes and which doc to find them in is located [here](https://www.silabs.com/documents/login/miscellaneous/SDS13548-List-of-defined-Z-Wave-Command-Classes.xlsx)
  """

  import Bitwise
  require Logger

  alias Grizzly.Security

  alias Grizzly.CommandClass.{
    Battery,
    Configuration,
    DoorLock,
    Mappings,
    NetworkManagementBasic,
    Notification,
    ThermostatFanMode,
    ThermostatFanState,
    ThermostatMode,
    ThermostatSetpoint,
    ThermostatSetback,
    UserCode,
    CommandClassVersion,
    SwitchMultilevel,
    NetworkManagementInclusion,
    MultilevelSensor,
    FirmwareUpdateMD,
    ManufacturerSpecific
  }

  def parse(<<
        0x34,
        0x02,
        seq_no,
        status,
        _,
        node_id,
        nif_len,
        listening?::size(1),
        _::size(7),
        _,
        basic,
        gen,
        specific,
        rest::binary
      >>)
      when status in [0x06, 0x09] do
    number_of_command_classes = nif_len - 6
    command_class_list = to_command_class_list(rest, number_of_command_classes)

    {keys_granted, kex_fail_type, dsk_length, dsk} =
      get_s2_security_info(rest, number_of_command_classes)

    status = decode_inclusion_status(status)

    %{
      command_class: :network_management_inclusion,
      command: :node_add_status,
      seq_no: seq_no,
      status: status,
      listening?: listening? == 1,
      node_id: node_id,
      basic_class: Mappings.byte_to_basic_class(basic),
      generic_class: Mappings.byte_to_generic_class(gen),
      specific_class: Mappings.byte_to_specific_class(gen, specific),
      command_classes: command_class_list,
      secure: keys_granted != [],
      keys_granted: keys_granted,
      kex_fail_type: Security.failed_type_from_byte(kex_fail_type),
      dsk_length: dsk_length,
      dsk: dsk
    }
  end

  def parse(<<0x34, 0x11, seq_no, _::size(7), csa?::size(1), requested_keys>>) do
    %{
      command_class: :network_management_inclusion,
      command: :node_add_keys_report,
      seq_no: seq_no,
      csa?: csa_to_boolean(csa?),
      requested_keys: Security.byte_to_keys(requested_keys)
    }
  end

  def parse(<<0x34, 0x13, seq_no, _::size(4), input_dsk_length::size(4), dsk::binary-size(16)>>) do
    %{
      command_class: :network_management_inclusion,
      command: :node_add_dsk_report,
      seq_no: seq_no,
      input_length: input_dsk_length,
      dsk: dsk
    }
  end

  def parse(<<0x34, 0x02, seq_no, 0x07, _::binary>>) do
    %{
      command_class: :network_management_inclusion,
      command: :node_add_status,
      seq_no: seq_no,
      status: :failed
    }
  end

  def parse(<<0x34, 0x04, seq_no, 0x06, node_id>>) do
    %{
      command_class: :network_management_inclusion,
      command: :node_remove_status,
      seq_no: seq_no,
      status: :done,
      node_id: node_id
    }
  end

  def parse(<<0x34, 0x04, seq_no, 0x07, _::binary>>) do
    %{
      command_class: :network_management_inclusion,
      command: :node_remove_status,
      seq_no: seq_no,
      status: :failed,
      node_id: nil
    }
  end

  def parse(<<0x34, 0x0C, seq_no, status_byte, _::binary>>) do
    %{
      command_class: :network_management_inclusion,
      command: :node_neighbor_update_status,
      seq_no: seq_no,
      status: NetworkManagementInclusion.decode_node_neighbor_update_status(status_byte)
    }
  end

  def parse(<<0x4D, 0x07, seq_no, status>>) do
    %{
      command_class: NetworkManagementBasic,
      command: :default_set_complete,
      seq_no: seq_no,
      status: NetworkManagementBasic.decode_default_set_status(status)
    }
  end

  def parse(<<0x4D, 0x02, seq_no, status, _reserved, new_node_id, _ignore::binary>>) do
    %{
      command_class: NetworkManagementBasic,
      command: :learn_mode_set_status,
      seq_no: seq_no,
      report: NetworkManagementBasic.decode_learn_mode_set_status(status, new_node_id)
    }
  end

  def parse(<<0x52, 0x02, seq_no, status, _controller_id, node_list::binary>>) do
    %{
      command_class: :network_management_proxy,
      command: :node_list_report,
      seq_no: seq_no,
      status: status,
      node_list:
        node_list
        |> unmask()
    }
  end

  def parse(<<
        0x52,
        0x04,
        _::binary-size(2),
        listening_node?::size(1),
        _::size(7),
        _,
        keys_granted,
        basic,
        gen,
        specific,
        command_classes::binary
      >>) do
    security =
      keys_granted
      |> Security.byte_to_keys()
      |> Security.get_highest_level()

    %{
      command_class: :network_management_proxy,
      command: :node_info_cache_report,
      report: %{
        basic_cmd_class: Mappings.byte_to_basic_class(basic),
        generic_cmd_class: Mappings.byte_to_generic_class(gen),
        specific_cmd_class: Mappings.byte_to_specific_class(gen, specific),
        command_classes: to_command_class_list(command_classes),
        listening?: byte_to_bool(listening_node?),
        security: security
      }
    }
  end

  def parse(
        <<0x71, 0x05, 0x00, 0x00, 0x00, _notification_status, notification_type,
          notification_state, _::binary>>
      ) do
    notification_type = Notification.type_from_byte(notification_type)

    report = %{
      command_class: :notification,
      command: :report,
      value: %{
        notification_type: notification_type,
        notification_state: Notification.state_from_byte(notification_type, notification_state)
      }
    }

    _ = Logger.debug("NOTIFICATION REPORT #{inspect(report)}")
    report
  end

  def parse(<<0x71, 0x05, alarm_type, alarm_level, _::binary>>) do
    alarm = %{
      command_class: :alarm,
      command: :report,
      value: %{
        alarm_type: alarm_type,
        alarm_level: alarm_level
      }
    }

    _ = Logger.debug("NOTIFICATION ALARM #{inspect(alarm)}")
    alarm
  end

  def parse(<<0x25, 0x03, switch_state>>) do
    %{
      command_class: :switch_binary,
      command: :report,
      value: encode_switch_state(switch_state)
    }
  end

  def parse(<<0x20, 0x03, value>>) do
    %{
      command_class: :basic,
      command: :report,
      value: encode_basic_value(value)
    }
  end

  def parse(<<0x26, 0x03, switch_state>>) do
    %{
      command_class: :switch_multilevel,
      command: :report,
      value: SwitchMultilevel.decode_switch_state(switch_state)
    }
  end

  def parse(<<
        0x31,
        0x05,
        enc_type,
        precision::size(3),
        _scale::size(2),
        size::size(3),
        value::signed-integer-size(size)-unit(8)
      >>) do
    level =
      (value * :math.pow(0.1, precision))
      |> Float.round(precision)
      |> round()

    type = MultilevelSensor.decode_type(enc_type)

    %{
      command_class: :sensor_multilevel,
      command: :report,
      value: %{
        type: type,
        level: level
      }
    }
  end

  def parse(<<0x45, 0x03, _reserved::size(4), state::size(4)>>) do
    %{
      command_class: :thermostat_fan_state,
      command: :report,
      value: ThermostatFanState.decode_state(state)
    }
  end

  def parse(<<0x40, 0x03, thermostat_mode::size(1), _rest::binary>>) do
    parse(<<0x40, 0x03, thermostat_mode>>)
  end

  def parse(<<0x40, 0x03, thermostat_mode>>) do
    %{
      command_class: :thermostat_mode,
      command: :report,
      value: ThermostatMode.mode_from_byte(thermostat_mode)
    }
  end

  def parse(<<0x47, 0x03, _reserved::size(6), type::size(2), state, _rest::binary>>) do
    %{
      command_class: :thermostat_setback,
      command: :report,
      report: %{
        type: ThermostatSetback.decode_setback_type(type),
        state: ThermostatSetback.decode_setback_state(state)
      }
    }
  end

  def parse(<<0x62, 0x03, mode, _::binary>>) do
    %{
      command_class: :door_lock,
      command: :report,
      value: DoorLock.decode_mode(mode)
    }
  end

  def parse(<<0x80, 0x03, battery_level>>) do
    %{
      command_class: :battery,
      command: :report,
      value: Battery.decode_level(battery_level)
    }
  end

  def parse(<<0x70, 0x06, param, size, value::signed-integer-size(size)-unit(8)>>) do
    %{
      command_class: Configuration,
      command: :report,
      value: %{
        param: param,
        value: value
      }
    }
  end

  def parse(<<
        0x70,
        0x09,
        parameter_offset::size(2)-big-integer-signed-unit(8),
        number,
        to_follow,
        _default::size(1),
        _handshake::size(1),
        _reserved::size(3),
        size::size(3),
        parameters::binary
      >>) do
    %{
      command_class: Configuration,
      command: :bulk_report,
      to_follow: to_follow,
      parameter_offset: parameter_offset,
      values: parse_configuration_parameters(parameters, size, number)
    }
  end

  def parse(<<
        0x32,
        0x02,
        scale_2::size(1),
        rate_type::size(2),
        meter_type::size(5),
        precision::size(3),
        scale_1::size(2),
        size::size(3),
        reading::size(size)-big-integer-signed-unit(8),
        _other::binary
      >>) do
    %{
      command_class: :meter,
      command: :meter_report,
      value: %{
        scale: scale_2 * 4 + scale_1,
        rate_type: rate_type,
        meter_type: meter_type,
        precision: precision,
        reading: reading
      }
    }
  end

  def parse(<<
        0x43,
        0x03,
        _reserved::size(4),
        setpoint_type::size(4),
        precision::size(3),
        _scale::size(2),
        size::size(3),
        reading::size(size)-integer-signed-unit(8)
      >>) do
    %{
      command_class: :thermostat_setpoint,
      command: :report,
      value: %{
        type: ThermostatSetpoint.decode_setpoint_type(setpoint_type),
        value:
          (reading * :math.pow(0.1, precision))
          |> Float.round(precision)
          |> round()
      }
    }
  end

  def parse(<<0x44, 0x03, fan_mode>>) do
    %{
      command_class: :thermostat_fan_mode,
      command: :report,
      value: ThermostatFanMode.decode_thermostat_fan_mode(fan_mode)
    }
  end

  def parse(<<0x63, 0x03, slot_id, slot_status, code::binary>>) do
    decoded_slot_status = UserCode.decode_slot_status(slot_status)

    %{
      command_class: :user_code,
      command: :report,
      value: %{
        slot_id: slot_id,
        slot_status: decoded_slot_status,
        code: code
      }
    }
  end

  def parse(<<0x63, 0x05, number>>) do
    %{
      command_class: :user_code,
      command: :users_number_report,
      value: number
    }
  end

  def parse(<<0x86, 0x14, report_data::binary>>) do
    value = CommandClassVersion.decode_report_data(report_data)

    %{
      command_class: CommandClassVersion,
      command: :report,
      value: value
    }
  end

  def parse(
        <<0x7A, 0x02, manufacturer_id::size(2)-integer-unsigned-unit(8),
          firmware_id::size(2)-integer-unsigned-unit(8), checksum::size(2)-binary-unit(8),
          _rest::binary>>
      ) do
    report = %{manufacturer_id: manufacturer_id, firmware_id: firmware_id, checksum: checksum}

    %{
      command_class: FirmwareUpdateMD,
      command: :report,
      value: report
    }
  end

  def parse(<<
        0x72,
        0x07,
        _reserved::size(5),
        device_id_type_byte::size(3),
        # UTF-8
        0x00::size(3),
        device_id_data_length::size(5),
        device_id_data::size(device_id_data_length)-binary-unit(8)
      >>) do
    device_id_type = ManufacturerSpecific.decode_device_id_type(device_id_type_byte)

    %{
      command_class: :manufacturer_specific,
      command: :device_specific_report,
      value: %{device_id_type: device_id_type, device_id: device_id_data}
    }
  end

  def parse(<<
        0x72,
        0x07,
        _reserved::size(5),
        device_id_type_byte::size(3),
        # Binary (hex)
        0x01::size(3),
        device_id_data_length::size(5),
        device_id_data_as_integer::size(device_id_data_length)-unit(8)
      >>) do
    device_id_type = ManufacturerSpecific.decode_device_id_type(device_id_type_byte)
    device_id_data = "h'" <> Integer.to_string(device_id_data_as_integer, 16)

    %{
      command_class: :manufacturer_specific,
      command: :device_specific_report,
      value: %{device_id_type: device_id_type, device_id: device_id_data}
    }
  end

  def parse(
        <<0x69, 0x03, _reserved::size(3), proxy_support::size(1), service_support::size(1),
          mode::size(3), mail_box_capacity::integer-size(16), ip_address::binary-size(16),
          udp_port::integer-size(16)>>
      ) do
    %{
      command_class: :mailbox,
      command: :mailbox_configuration_report,
      proxy_support: proxy_support == 1,
      service_support: service_support == 1,
      mode: Grizzly.CommandClass.Mailbox.mode_from_byte(mode),
      mail_box_capacity: mail_box_capacity,
      service_ip: ip_address,
      udp_port: udp_port
    }
  end

  def parse(<<0x84, 0x06, seconds::size(3)-unit(8), node_id, _rest::binary()>>) do
    %{
      command_class: :wake_up,
      command: :wake_up_interval_report,
      value: %{
        seconds: seconds,
        node_id: node_id
      }
    }
  end

  def parse(
        <<0x84, 0x0A, min_interval::size(3)-unit(8), max_interval::size(3)-unit(8),
          default_interval::size(3)-unit(8), interval_step::size(3)-unit(8)>>
      ) do
    %{
      command_class: Mappings.from_byte(0x84),
      command: Mappings.command_from_byte(0x84, 0x0A),
      min_interval: min_interval,
      max_interval: max_interval,
      default_interval: default_interval,
      interval_step: interval_step
    }
  end

  def parse(<<0x85, 0x03, _group, _max_nodes, _reports_to_follow, nodes::binary>>) do
    %{
      command_class: Mappings.from_byte(0x85),
      command: Mappings.command_from_byte(0x85, 0x06),
      nodes: :erlang.binary_to_list(nodes)
    }
  end

  def parse(<<command_class, command, rest_of_body::binary>> = packet) do
    _ = Logger.info("Default parsing of packet body #{inspect(packet)}")
    parsed_command_class = Mappings.from_byte(command_class)
    parsed_command = Mappings.command_from_byte(command_class, command)

    make_parsed_body(parsed_command_class, parsed_command, rest_of_body)
  end

  def parse(body) do
    body
  end

  defp make_parsed_body(command_class, {:unk, _} = command, body) do
    %{
      command_class: command_class,
      command: command,
      value: body
    }
  end

  defp make_parsed_body(
         :manufacturer_specific,
         :manufacturer_specific_report,
         <<man_id::size(16), prod_type_id::size(16), prod_id::size(16)>>
       ) do
    %{
      command_class: :manufacturer_specific,
      command: :manufacturer_specific_report,
      manufacturer_id: man_id,
      product_type_id: prod_type_id,
      product_id: prod_id
    }
  end

  defp make_parsed_body(command_class, command, body) do
    %{
      command_class: command_class,
      command: command,
      value: body
    }
  end

  defp encode_switch_state(0x00), do: :off
  defp encode_switch_state(0xFF), do: :on
  defp encode_switch_state(0xFE), do: :unknown

  defp encode_basic_value(0x00), do: :off
  defp encode_basic_value(0xFF), do: :on
  defp encode_basic_value(_), do: :unknown

  defp parse_command_class(byte, cmd_classes) when byte in [0x00, 0xEF, 0xF1], do: cmd_classes

  defp parse_command_class(byte, cmd_classes) do
    cmd_classes ++ [Mappings.from_byte(byte)]
  end

  defp unmask(mask) do
    unmask(0, [], mask)
  end

  defp unmask(_, xs, <<>>), do: Enum.sort(xs)

  defp unmask(offset, xs, <<byte::binary-size(1), rest::binary>>) do
    xs = Enum.concat(xs, get_digits(offset, byte))
    unmask(offset + 8, xs, rest)
  end

  defp get_digits(_, <<0>>), do: []

  defp get_digits(offset, byte) do
    Enum.reduce(
      1..8,
      [],
      fn position, acc ->
        case bit_at?(position, byte) do
          true -> [position + offset | acc]
          false -> acc
        end
      end
    )
  end

  defp bit_at?(position, <<byte>>) do
    (1 <<<
       (position - 1) &&& byte) != 0
  end

  defp byte_to_bool(0), do: false
  defp byte_to_bool(1), do: true

  defp parse_configuration_parameters(parameters, size, number) do
    _ =
      Logger.debug(
        "Parsing #{number} configuration parameters #{inspect(parameters)} of size #{size}"
      )

    parameter_bytes = :erlang.binary_to_list(parameters)

    if Enum.count(parameter_bytes) >= size * number do
      Enum.take(parameter_bytes, size * number)
      |> Enum.chunk_every(size)
      |> Enum.map(&:erlang.list_to_binary(&1))
    else
      _ =
        Logger.warn(
          "Wrong number of configuration parameters #{inspect(parameter_bytes)} of size #{size}. Expecting at least #{
            number
          }"
        )

      []
    end
  end

  defp csa_to_boolean(1), do: true
  defp csa_to_boolean(0), do: false

  defp to_command_class_list(binary, number_of_command_classes) do
    <<command_classes::binary-size(number_of_command_classes), _::binary>> = binary
    to_command_class_list(command_classes)
  end

  defp to_command_class_list(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce([], &parse_command_class/2)
  end

  defp get_s2_security_info(command_include_binary, command_include_length) do
    <<
      _::binary-size(command_include_length),
      keys_granted,
      kex_fail_type,
      dsk_length,
      dsk::binary
    >> = command_include_binary

    {Security.byte_to_keys(keys_granted), kex_fail_type, dsk_length, dsk}
  end

  defp decode_inclusion_status(0x06), do: :done
  defp decode_inclusion_status(0x09), do: :security_failed
end