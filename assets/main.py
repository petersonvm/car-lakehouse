"""
Dummy Lambda Handler for Testing
This is a placeholder function for Terraform deployment testing.
Replace this with your actual ETL/data processing code.
"""

def handler(event, context):
    """
    Lambda function handler
    
    Args:
        event: Lambda event object
        context: Lambda context object
        
    Returns:
        dict: Response object
    """
    print(f"Event: {event}")
    print(f"Context: {context}")
    
    return {
        'statusCode': 200,
        'body': 'Hello from Lambda!'
    }
