# Generate the SQL migration for configuring timeseries maintenance

import os
import json

manifests_dir = "../../../protos/manifests/"
sql_template_path = "./configure_timeseries_maintenance_template/configure_timeseries_maintenance.sql"
output_dir = "./"

def generate_migration(output_dir: str):
    """
    Generate code defining manifest variables
    """
    output_code = "-- Generated SQL code for configuring timeseries maintenance\n\n"

    # load template
    sql_template = ""
    with open(sql_template_path, 'r') as file:
        sql_template = file.read()

    # load manifests and gather table names
    table_names = []
    for file_name in os.listdir(manifests_dir):
        with open(os.path.join(manifests_dir, file_name), 'r') as file:
            manifest_json = json.load(file)
            for entry in manifest_json:
                table_name = entry["ProtoDefName"].replace(".", "_").lower()
                table_names.append(table_name)

    # create SQL by copying over template with table name substituted for each table
    for table_name in table_names:
        output_code += sql_template.replace("{table_name}", table_name) + "\n"
            
    with open(os.path.join(output_dir, "V4__configure_timeseries_maintenance.sql"), 'w') as file:
        file.write(output_code)

generate_migration(output_dir)