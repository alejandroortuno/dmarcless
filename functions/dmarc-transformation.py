from xml.etree.ElementTree import fromstring, ElementTree
import time, datetime, os
import json
import boto3
import urllib

S3R = boto3.resource('s3')
OUTPUT_BUCKET_NAME = os.environ['OUTPUT_BUCKET_NAME']

print('Loading function')


def lambda_handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = urllib.unquote_plus(event['Records'][0]['s3']['object']['key']).decode('utf8')
    filename = key.rsplit('.', 1)[0].split('/')[-1]  # Without the extension

    try:
        print('Getting S3 content for bucket:' + bucket)
        s3_content = S3R.Bucket(bucket).Object(key).get()["Body"].read()
        if "entity" in s3_content.lower() or "system" in s3_content.lower():
            # Use error keyword as cloudwatch alert looking for this
            raise Exception("Error: Injection attempt for bucket file name:" + bucket)
        print('Parsing XML into a dictionary')
        xml_list = parse_dmarc_xml_to_list(s3_content, filename)
        print('Uploading the list into a JSON file on S3. Key:' + key)
        upload_dmarc_json_to_s3(xml_list, filename)

    except Exception as e:
        print(e)
        raise e


def parse_dmarc_xml_to_list(xml_string, filename):
    """
    
    :param xml_string: string with the content of the XML file
    :return: List of dict with the records and the metadata in each record
    """

    try:
        # create element tree object
        tree = ElementTree(fromstring(xml_string))
    except Exception:
        # Some reports contain xml format errors. Killing function nicely so lambda does not retry the function.
        # TODO: Dead Letter Queue
        # Avoiding word Error so cloud watch alert is not triggered.
        print ("Not well format for file name:" + filename)
        exit(0)

    # get root element
    root = tree.getroot()

    # Metadata - Only the one interested in
    date_parsed = datetime.datetime.fromtimestamp(time.time()).strftime('%Y-%m-%d %H:%M:%S')
    org_name = root.findtext("report_metadata/org_name", default="none")
    report_id = root.findtext("report_metadata/report_id", default="none")

    # records
    records_list = []
    for record in root.findall("record"):
        record_dict = {}

        # Add metadata to the record
        record_dict.update({"date": date_parsed})
        record_dict.update({"org_name": org_name})
        record_dict.update({"report_id": report_id})
        record_dict.update({"file_name": filename})

        record_dict.update({"source_ip": record.findtext("row/source_ip", default="none")})
        record_dict.update({"count": record.findtext("row/count", default="none")})
        record_dict.update({"disposition": record.findtext("row/policy_evaluated/disposition", default="none")})
        record_dict.update({"policy_dkim": record.findtext("row/policy_evaluated/dkim", default="none")})
        record_dict.update({"policy_spf": record.findtext("row/policy_evaluated/spf", default="none")})
        record_dict.update({"type": record.findtext("row/policy_evaluated/reason/type", default="none")})
        record_dict.update({"header_from": record.findtext("identifiers/header_from", default="none")})
        record_dict.update({"envelope_from": record.findtext("identifiers/envelope_from", default="none")})
        record_dict.update({"envelope_to": record.findtext("identifiers/envelope_to", default="none")})
        record_dict.update({"human_result": record.findtext("auth_results/dkim/human_result", default="none")})
        record_dict.update({"spf_domain": record.findtext("auth_results/spf/domain", default="none")})
        record_dict.update({"spf_result": record.findtext("auth_results/spf/result", default="none")})
        record_dict.update({"spf_scope": record.findtext("auth_results/spf/scope", default="none")})

        # DKIM can be a list as multiple signing can happen.
        dkim_results = []
        for dkim in record.findall("auth_results/dkim"):
            dkim_dict = {}
            dkim_dict.update({"dkim_domain": dkim.findtext("domain", default="none")})
            dkim_dict.update({"dkim_result": dkim.findtext("result", default="none")})
            dkim_dict.update({"dkim_selector": dkim.findtext("selector", default="none")})
            dkim_results.append(dkim_dict)
        record_dict.update({"dkim": dkim_results})
        records_list.append(record_dict)
    return records_list


def upload_dmarc_json_to_s3(recordList, filename):
    print('Temporarely saving the dict into a file')
    tmp_file_name = '/tmp/dmarc.json'
    g = open(tmp_file_name, 'w')
    for record in recordList:
        g.write(json.dumps(record) + '\n')
    g.close()

    # Upload the json file to S3
    print('Uploading the JSON into the destination bucket for report id' + filename)
    S3R.meta.client.upload_file(tmp_file_name, OUTPUT_BUCKET_NAME, filename + '.json')
