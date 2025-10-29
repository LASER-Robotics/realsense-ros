import os

from launch import LaunchContext, LaunchDescription

from launch.actions import DeclareLaunchArgument, OpaqueFunction

from launch.substitutions import LaunchConfiguration, PathJoinSubstitution, TextSubstitution, PythonExpression

from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterFile
from launch_ros.substitutions import FindPackageShare


def launch_setup(context: LaunchContext):
    # Initialize arguments
    uav_name = LaunchConfiguration('uav_name')
    use_sim_time = LaunchConfiguration('use_sim_time')
    camera_name = LaunchConfiguration('camera_name')
    camera_params_file = LaunchConfiguration('camera_params_file')


    # Declare nodes
    realsense_camera_node = Node(
        package='realsense2_camera',
        executable='realsense2_camera_node',
        name=camera_name,
        namespace=uav_name,
        output='screen',
        parameters=[ParameterFile(camera_params_file, allow_substs=True),
                    {'use_sim_time': use_sim_time}])

    return [realsense_camera_node]


def generate_launch_description():
    # Declare arguments
    declared_arguments = []

    declared_arguments.append(
        DeclareLaunchArgument(
            'uav_name',
            default_value=os.getenv('UAV_NAME', "uav1"),
            description='Top-level namespace.'))

    declared_arguments.append(
        DeclareLaunchArgument(
            'use_sim_time',
            default_value=PythonExpression(['"', os.getenv('REAL_UAV', "true"), '" == "false"']),
            description='Whether use the simulation time.'))

    declared_arguments.append(
        DeclareLaunchArgument(
            'camera_name',
            default_value='rgbd',
            description='Camera name.'))

    declared_arguments.append(
        DeclareLaunchArgument(
            'camera_params_file',
            default_value=PathJoinSubstitution([FindPackageShare('realsense2_camera'),
                                                'params', 'default.yaml']), # NOTE: we ONLY have this config available for now
            description='Full path to the file with the camera parameters.'))

    return LaunchDescription(declared_arguments + [OpaqueFunction(function=launch_setup)])
