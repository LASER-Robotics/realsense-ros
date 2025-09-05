import os

import launch

from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.conditions import IfCondition, UnlessCondition
from launch.substitutions import (
    LaunchConfiguration,
    PythonExpression,
    TextSubstitution
    )

from launch_ros.actions import ComposableNodeContainer, LoadComposableNodes, Node
from launch_ros.descriptions import ComposableNode
from launch_ros.parameter_descriptions import ParameterFile


def launch_setup(context: launch.LaunchContext, ld):
    namespace = 'realsense2_camera'

    # #{ uav_name

    uav_name = LaunchConfiguration('uav_name')
    _uav_name = uav_name.perform(context)

    # #}

    # #{ camera_name

    camera_name = LaunchConfiguration('camera_name')
    _camera_name = camera_name.perform(context)

    # #}

    # #{ standalone

    standalone = LaunchConfiguration('standalone')

    ld.add_action(DeclareLaunchArgument(
        'standalone',
        default_value='true',
        description='Whether to start as a container or load into an existing container.'
    ))

    # #}

    # #{ container_name

    container_name = LaunchConfiguration('container_name')

    ld.add_action(DeclareLaunchArgument(
        'container_name',
        default_value='',
        description='Name of an existing container to load into (if standalone is false)'
    ))

    # #}

    # #{ use_sim_time

    use_sim_time = LaunchConfiguration('use_sim_time')

    ld.add_action(DeclareLaunchArgument(
        'use_sim_time',
        default_value=PythonExpression(['"', os.getenv('REAL_UAV', 'true'), '" == "false"']),
        description='Whether use the simulation time.'
    ))

    # #}

    # #{ log_level

    log_level = LaunchConfiguration('log_level')

    ld.add_action(DeclareLaunchArgument(
        'log_level',
        default_value='info',
        description='Log level.'
    ))

    # #}

    # #{ realsense_config

    realsense_config = LaunchConfiguration('realsense_config')

    ld.add_action(DeclareLaunchArgument(
        'realsense_config',
        default_value='',
        description='Path to the Realsense camera configuration file.'
    ))

    # #}

    # #{ realsense camera node

    realsense_camera_node = ComposableNode(

        package='realsense2_camera',
        plugin='realsense2_camera::RealSenseNodeFactory',
        namespace=uav_name,
        name=camera_name,

        parameters=[
            ParameterFile(realsense_config, allow_substs=True),
        ]
    )

    load_into_existing = LoadComposableNodes(
        target_container=container_name,
        composable_node_descriptions=[realsense_camera_node],
        condition=UnlessCondition(standalone)
    )

    ld.add_action(load_into_existing)

    # #}

    # #{ standalone container

    standalone_container = ComposableNodeContainer(
        namespace=uav_name,
        name=namespace+'_container',
        package='rclcpp_components',
        executable='component_container_mt',
        output='screen',
        arguments=['--ros-args', '--log-level', log_level],
        composable_node_descriptions=[realsense_camera_node],
        condition=IfCondition(standalone)
    )

    ld.add_action(standalone_container)

    # #}

    # #{ static transformer publisher node

    fcu_frame = _uav_name + '/fcu'
    fcu_frame_slashless = 'fcu_' + _uav_name

    realsense_frame = _uav_name + '/' + _camera_name + '/link'
    realsense_frame_slashless = _uav_name + '_' + _camera_name + '_link'

    fcu_to_realsense_tf_static_publisher_node = Node(
        package='tf2_ros',
        executable='static_transform_publisher',
        name=TextSubstitution(text=fcu_frame_slashless + '_to_' + realsense_frame_slashless),
        namespace=uav_name,
        output='screen',
        parameters=[
            {'use_sim_time': use_sim_time}
        ],
        arguments=[
            '--x', '0.0',
            '--y', '0.0',
            '--z', '0.15',
            '--yaw', '0.0',
            '--pitch', '0.0',
            '--roll', '0.0',
            '--frame-id', fcu_frame,
            '--child-frame-id', realsense_frame
        ]
    )

    ld.add_action(fcu_to_realsense_tf_static_publisher_node)

    # #}


def generate_launch_description():
    ld = launch.LaunchDescription()

    # #{ uav_name

    ld.add_action(DeclareLaunchArgument(
        'uav_name',
        default_value=os.getenv('UAV_NAME', 'uav1'),
        description='Top-level namespace.'
    ))

    # #}

    # #{ camera_name

    ld.add_action(DeclareLaunchArgument(
        'camera_name',
        default_value='rgbd',
        description='Camera name.'
    ))

    # #}

    # #{ opaque function

    ld.add_action(
        OpaqueFunction(function=launch_setup, args=[ld])
    )

    # #}

    return ld
